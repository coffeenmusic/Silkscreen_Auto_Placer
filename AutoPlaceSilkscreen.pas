// How to use:
// 1) Run script from pcb layout
// 2) Any unplaced silkscreen will be moved off the board
// 3) A popup message box will appear on completion

// HALT EXECUTION: ctrl + PauseBreak

// Performance notes:
// - Obstacles (pads, tracks, arcs, vias, component bodies, other silkscreen) are
//   cached once per component into in-memory rectangle lists. Candidate positions
//   are then tested with pure integer math instead of spatial iterators, which is
//   orders of magnitude faster on big boards.
// - Trial moves are done without BeginModify/EndModify; only the final accepted
//   position is committed with proper undo/notification bracketing.

// TODO:
// - Iterate through all good placement positions, use the one with the lowest x/y --> x2/y2 delta square distance
// - Only allow 2 silk designators close to eachother if they are perpendicular to eachother
// - Option to move unplaced silkscreen on top of components at the end of the script?
// - Add Mechanical Layer options to GUI
// - Use Courtyard layer tracks

uses
  Winapi, ShellApi, Win32.NTDef, Windows, Messages, SysUtils, Classes,
  Graphics,
  Controls, Forms, Dialogs, System, System.Diagnostics;

const
  NEWLINECODE = #13#10;
  TEXTBOXINIT = 'Example:' + NEWLINECODE + 'J3' + NEWLINECODE + 'SH1';
  SLKPAD = 40000; // Allowed silk-to-silk designator overlap = 4 mil
  PADPAD = 10000; // Margin beyond pad = 1 mil
  // TList stores untyped pointers: on 64-bit Altium they read back as unsigned,
  // so negative values overflow. All coordinates stored in the obstacle TLists
  // are offset by this bias to guarantee they stay positive.
  COORD_BIAS = 100000000;

var
  AllowUnderList: TStringList;
  MechLayerIDList: TStringList;
  Board: IPCB_Board;
  CmpOutlineLayerID: Integer;
  AvoidVias: Boolean;
  DictionaryCache: TStringList;
  TextProperites: TStringList;
  FormCheckListBox1: TCheckListBox;
  SilkscreenPositionDelta: TCoord;
  SilkscreenFixedWidth: TCoord;
  SilkscreenFixedSize: TCoord;
  SilkscreenIsFixedWidth: Boolean;
  SilkscreenIsFixedSize: Boolean;
  TryAlteredRotation: Integer;
  RotationStrategy: Integer;
  WiggleEnabled: Boolean;
  UnhideAllDesignators: Boolean;

  // Obstacle cache. Rebuilt once per component; rectangles are stored with any
  // padding margins and COORD_BIAS already baked in so candidate tests are
  // simple positive-vs-positive compares (never signed arithmetic on TList items).
  ObsAL, ObsAB, ObsAR, ObsAT: TList; // Pads/tracks/arcs/vias/component bodies
  ObsBL, ObsBB, ObsBR, ObsBT: TList; // Silkscreen text on the same overlay
  // Base candidate rectangle/anchor per enabled autoposition (current
  // size/rotation). Stored as strings so StrToInt returns clean signed
  // integers that are safe to add negative offsets to.
  BaseL, BaseB, BaseR, BaseT: TStringList;
  BaseX, BaseY, BaseIdx: TStringList;
  BoardRect: TCoordRect;
  BoardIsRectangular: Boolean;

  // May want different Bounding Rectangles depending on the object
function Get_Obj_Rect(Obj: IPCB_ObjectClass): TCoordRect;
var
  Rect: TCoordRect;
  ObjID: Integer;
begin
  ObjID := Obj.ObjectId;
  if ObjID = eBoardObject then
  begin
    Rect := Obj.BoardOutline.BoundingRectangle;
  end
  else if ObjID = eComponentObject then
  begin
    // Rect := Obj.BoundingRectangleNoNameComment;
    Rect := Obj.BoundingRectangleNoNameCommentForSignals;
  end
  else
  begin
    Rect := Obj.BoundingRectangle;
  end;

  result := Rect;
end;

// Guess silkscreen size based on component size
function Get_Silk_Size(Slk: IPCB_Text; Min_Size: Integer): Integer;
var
  Rect: TCoordRect;
  area: Integer;
  size: Integer;
begin
  // Stroke Width & Text Height
  Rect := Get_Obj_Rect(Slk.Component);
  area := CoordToMils(Rect.Right - Rect.Left) *
    CoordToMils(Rect.Top - Rect.Bottom);

  size := Int((82 * area) / (16700 + area));
  if size < Min_Size then
    size := Min_Size;

  result := size;
end;

// Returns correct layer set given the object being used
function Get_LayerSet(SlkLayer: Integer; ObjID: Integer): PAnsiChar;
var
  TopBot: Integer;
begin
  TopBot := eTopLayer;
  if (Layer2String(SlkLayer) = 'Bottom Overlay') then
    TopBot := eBottomLayer;

  result := MkSet(SlkLayer); // Default layer set
  if (ObjID = eComponentObject) or (ObjID = ePadObject) or (ObjID = eViaObject)
  then
  begin
    result := MkSet(TopBot, eMultiLayer);
  end
  else if (ObjID = eComponentBodyObject) then
  begin
    result := MkSet(CmpOutlineLayerID);
  end;
end;

function Allow_Under(Cmp: IPCB_Component; AllowUnderList: TStringList): Boolean;
var
  refdes: TPCB_String;
  i: Integer;
begin
  if (AllowUnderList <> nil) and (AllowUnderList.Count > 0) then
  begin
    For i := 0 to AllowUnderList.Count - 1 do
    begin
      refdes := LowerCase(AllowUnderList.Get(i));
      if LowerCase(Cmp.Name.Text) = refdes then
      begin
        result := True;
        Exit;
      end;
    end;
  end;
  result := False;
end;

// Add one obstacle rectangle to the cache. GroupB is silkscreen text, which the
// moving designator is allowed to overlap by SLKPAD. COORD_BIAS keeps every
// stored value positive so it survives the round trip through TList pointers.
procedure Cache_Add_Rect(GroupB: Boolean; L: TCoord; B: TCoord; R: TCoord;
  T: TCoord);
begin
  if GroupB then
  begin
    ObsBL.Add(L + COORD_BIAS);
    ObsBB.Add(B + COORD_BIAS);
    ObsBR.Add(R + COORD_BIAS);
    ObsBT.Add(T + COORD_BIAS);
  end
  else
  begin
    ObsAL.Add(L + COORD_BIAS);
    ObsAB.Add(B + COORD_BIAS);
    ObsAR.Add(R + COORD_BIAS);
    ObsAT.Add(T + COORD_BIAS);
  end;
end;

// Collect every obstacle rectangle near the component with a single set of
// spatial queries. All candidate positions are then tested purely in memory.
procedure Build_Obstacle_Cache(Slk: IPCB_Text; RegionL: TCoord; RegionB: TCoord;
  RegionR: TCoord; RegionT: TCoord);
var
  Iterator: IPCB_SpatialIterator;
  Obj: IPCB_ObjectClass;
  Cmp: IPCB_Component;
  Rect: TCoordRect;
  Delta: TCoord;
begin
  ObsAL.Clear;
  ObsAB.Clear;
  ObsAR.Clear;
  ObsAT.Clear;
  ObsBL.Clear;
  ObsBB.Clear;
  ObsBR.Clear;
  ObsBT.Clear;

  // Silkscreen text, tracks & arcs on the same overlay layer
  Iterator := Board.SpatialIterator_Create;
  Iterator.AddFilter_ObjectSet(MkSet(eTextObject, eTrackObject, eArcObject));
  Iterator.AddFilter_LayerSet(MkSet(Slk.Layer));
  Iterator.AddFilter_Area(RegionL, RegionB, RegionR, RegionT);
  Obj := Iterator.FirstPCBObject;
  while Obj <> nil do
  begin
    if not Obj.IsHidden then
    begin
      if Obj.ObjectId = eTextObject then
      begin
        // Skip the designator currently being placed
        if not (Obj.IsDesignator and (Obj.Text = Slk.Text)) then
        begin
          Rect := Get_Obj_Rect(Obj);
          // Designators tolerate a small mutual overlap (SLKPAD, baked in here)
          Delta := 0;
          if Obj.IsDesignator then
            Delta := SLKPAD;
          Cache_Add_Rect(True, Rect.Left + Delta, Rect.Bottom + Delta,
            Rect.Right - Delta, Rect.Top - Delta);
        end;
      end
      else
      begin
        Rect := Obj.BoundingRectangle;
        Cache_Add_Rect(False, Rect.Left, Rect.Bottom, Rect.Right, Rect.Top);
      end;
    end;
    Obj := Iterator.NextPCBObject;
  end;
  Board.SpatialIterator_Destroy(Iterator);

  // Pads (and optionally vias) on the same side of the board or multilayer
  Iterator := Board.SpatialIterator_Create;
  if AvoidVias then
    Iterator.AddFilter_ObjectSet(MkSet(ePadObject, eViaObject))
  else
    Iterator.AddFilter_ObjectSet(MkSet(ePadObject));
  Iterator.AddFilter_LayerSet(Get_LayerSet(Slk.Layer, ePadObject));
  Iterator.AddFilter_Area(RegionL, RegionB, RegionR, RegionT);
  Obj := Iterator.FirstPCBObject;
  while Obj <> nil do
  begin
    if not Obj.IsHidden then
    begin
      Delta := 0;
      if Obj.ObjectId = ePadObject then
        Delta := PADPAD;
      Rect := Obj.BoundingRectangle;
      Cache_Add_Rect(False, Rect.Left - Delta, Rect.Bottom - Delta,
        Rect.Right + Delta, Rect.Top + Delta);
    end;
    Obj := Iterator.NextPCBObject;
  end;
  Board.SpatialIterator_Destroy(Iterator);

  // Component bodies -> parent component footprint rectangles
  if CmpOutlineLayerID <> 0 then
  begin
    Iterator := Board.SpatialIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
    Iterator.AddFilter_LayerSet(MkSet(CmpOutlineLayerID));
    Iterator.AddFilter_Area(RegionL, RegionB, RegionR, RegionT);
    Obj := Iterator.FirstPCBObject;
    while Obj <> nil do
    begin
      if not Obj.IsHidden then
      begin
        Cmp := Obj.Component;

        // Allow under are user defined reference designators that can be ignored
        if (Cmp <> nil) and (not Allow_Under(Cmp, AllowUnderList)) and
          (Cmp.Name.Layer = Slk.Layer) then
        begin
          Rect := Get_Obj_Rect(Cmp);
          Cache_Add_Rect(False, Rect.Left, Rect.Bottom, Rect.Right, Rect.Top);
        end;
      end;
      Obj := Iterator.NextPCBObject;
    end;
    Board.SpatialIterator_Destroy(Iterator);
  end;
end;

// Pure in-memory test of one candidate rectangle against the board edge and
// the cached obstacles. No API calls except PointInPolygon on odd-shaped boards.
function Candidate_Is_Clear(L: TCoord; B: TCoord; R: TCoord;
  T: TCoord): Boolean;
var
  i: Integer;
  Lb, Bb, Rb, Tb: TCoord;
  Ls, Bs, Rs, Ts: TCoord;
begin
  result := False;

  // Board edge (bounding rectangle), tested on real coordinates
  if (L < BoardRect.Left) or (R > BoardRect.Right) or (B < BoardRect.Bottom) or
    (T > BoardRect.Top) then
    Exit;

  // Obstacle rectangles are stored biased positive (see Cache_Add_Rect), so
  // shift the candidate into the same domain before comparing
  Lb := L + COORD_BIAS;
  Bb := B + COORD_BIAS;
  Rb := R + COORD_BIAS;
  Tb := T + COORD_BIAS;

  // Pads, vias, tracks, arcs & component bodies
  For i := 0 to ObsAL.Count - 1 do
  begin
    if not((Bb > ObsAT.Items[i]) or (Tb < ObsAB.Items[i]) or
      (Lb > ObsAR.Items[i]) or (Rb < ObsAL.Items[i])) then
      Exit;
  end;

  // Other silkscreen text; the moving designator shrinks by SLKPAD too
  Ls := Lb + SLKPAD;
  Bs := Bb + SLKPAD;
  Rs := Rb - SLKPAD;
  Ts := Tb - SLKPAD;
  For i := 0 to ObsBL.Count - 1 do
  begin
    if not((Bs > ObsBT.Items[i]) or (Ts < ObsBB.Items[i]) or
      (Ls > ObsBR.Items[i]) or (Rs < ObsBL.Items[i])) then
      Exit;
  end;

  // Non-rectangular board outlines: all four corners must be inside the outline
  if not BoardIsRectangular then
  begin
    if not Board.BoardOutline.PointInPolygon(L, B) then
      Exit;
    if not Board.BoardOutline.PointInPolygon(L, T) then
      Exit;
    if not Board.BoardOutline.PointInPolygon(R, B) then
      Exit;
    if not Board.BoardOutline.PointInPolygon(R, T) then
      Exit;
  end;

  result := True;
end;

// Moves silkscreen reference designators to board origin. Used as initialization step.
procedure Move_Silk_Off_Board(OnlySelected: Boolean);
var
  Iterator: IPCB_BoardIterator;
  Slk: IPCB_Text;
begin
  Iterator := Board.BoardIterator_Create;
  Iterator.AddFilter_ObjectSet(MkSet(eTextObject));
  Iterator.AddFilter_IPCB_LayerSet(MkSet(eTopOverlay, eBottomOverlay));
  Iterator.AddFilter_Method(eProcessAll);

  // Iterate through silkscreen reference designators.
  Slk := Iterator.FirstPCBObject;
  while Slk <> nil do
  begin
    // Leave hidden designators alone (e.g. hidden by a previous run)
    if Slk.IsDesignator and (not Slk.IsHidden) then
    begin
      if (OnlySelected and Slk.Component.Selected) or (not OnlySelected) then
      begin
        TextProperites.Add(Slk.Text + '.Rotation=' + IntToStr(Slk.Rotation));
        TextProperites.Add(Slk.Text + '.Width=' + IntToStr(Slk.Width));
        TextProperites.Add(Slk.Text + '.Size=' + IntToStr(Slk.size));
        TextProperites.Add(Slk.Text + '.XLocation=' + IntToStr(Slk.XLocation));
        TextProperites.Add(Slk.Text + '.YLocation=' + IntToStr(Slk.YLocation));

        Slk.BeginModify;
        Slk.MoveToXY(Board.XOrigin - 1000000, Board.YOrigin - 1000000);
        Slk.EndModify;
        // Move slightly off board origin
      end;
    end;

    Slk := Iterator.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iterator);
end;

// Turn the Designator display back on for every component so previously
// hidden designators are included in the placement run
procedure Unhide_All_Designators(Dummy: Integer);
var
  Iterator: IPCB_BoardIterator;
  Cmp: IPCB_Component;
begin
  Iterator := Board.BoardIterator_Create;
  Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iterator.AddFilter_LayerSet(MkSet(eTopLayer, eBottomLayer));
  Iterator.AddFilter_Method(eProcessAll);

  Cmp := Iterator.FirstPCBObject;
  while Cmp <> nil do
  begin
    if not Cmp.NameOn then
    begin
      Cmp.BeginModify;
      Cmp.NameOn := True;
      Cmp.EndModify;
    end;
    Cmp := Iterator.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iterator);
end;

// Hide designators that could not be placed. They are centered on their
// component first so they sit in a sensible spot if ever unhidden.
procedure Hide_Designators(SlkList: TObjectList);
var
  Slk: IPCB_Text;
  i: Integer;
begin
  For i := 0 to SlkList.Count - 1 do
  begin
    Slk := SlkList[i];

    Slk.BeginModify;
    Slk.Component.ChangeNameAutoposition := eAutoPos_CenterCenter;
    Slk.EndModify;

    Slk.Component.BeginModify;
    Slk.Component.NameOn := False;
    Slk.Component.EndModify;
  end;
end;

procedure Move_Silk_Over_Comp(SlkList: TObjectList);
var
  Slk: IPCB_Text;
  i: Integer;
begin
  For i := 0 to SlkList.Count - 1 do
  begin
    Slk := SlkList[i];

    Slk.BeginModify;
    Slk.Component.ChangeNameAutoposition := eAutoPos_CenterCenter;
    Slk.EndModify;
  end;
end;

procedure Restore_Comp(SlkList: TObjectList);
var
  Slk: IPCB_Text;
  i: Integer;
  _Index: Integer;
  X, Y: Integer;
begin
  For i := 0 to SlkList.Count - 1 do
  begin
    Slk := SlkList[i];

    _Index := TextProperites.IndexOfName(Slk.Text + '.Rotation');
    if _Index < 0 then
      Continue; // No stored properties for this designator

    Slk.BeginModify;

    Slk.Rotation := TextProperites.ValueFromIndex[_Index];

    _Index := TextProperites.IndexOfName(Slk.Text + '.Width');
    Slk.Width := TextProperites.ValueFromIndex[_Index];

    _Index := TextProperites.IndexOfName(Slk.Text + '.Size');
    Slk.size := TextProperites.ValueFromIndex[_Index];

    Slk.EndModify;

    Slk.BeginModify;

    _Index := TextProperites.IndexOfName(Slk.Text + '.XLocation');
    X := TextProperites.ValueFromIndex[_Index];

    _Index := TextProperites.IndexOfName(Slk.Text + '.YLocation');
    Y := TextProperites.ValueFromIndex[_Index];

    Slk.MoveToXY(X, Y);

    Slk.EndModify;
  end;
end;

function StrToAutoPos(iteration: String): Integer;
begin
  Case iteration of
    'CenterRight':
      result := eAutoPos_CenterRight;
    'TopCenter':
      result := eAutoPos_TopCenter;
    'CenterLeft':
      result := eAutoPos_CenterLeft;
    'BottomCenter':
      result := eAutoPos_BottomCenter;
    'TopLeft':
      result := eAutoPos_TopLeft;
    'TopRight':
      result := eAutoPos_TopRight;
    'BottomLeft':
      result := eAutoPos_BottomLeft;
    'BottomRight':
      result := eAutoPos_BottomRight;
  else
    result := -1;
  end;
end;

procedure AutoPosDeltaAdjust(autoPos: Integer; X_offset: Integer;
  Y_offset: Integer; Silk: IPCB_Text; Layer: TPCBString);
var
  dx, dy, d: Integer;
  XOrigin, YOrigin: Integer;
  flipx: Integer;
  R: Integer;
begin
  d := SilkscreenPositionDelta;
  dx := 0;
  dy := 0;
  R := Silk.Rotation;
  flipx := 1; // x Direction flips on the bottom layer
  if Layer = 'Bottom Layer' then
    flipx := -1;

  Case autoPos of
    eAutoPos_CenterRight:
      dx := -d * flipx;
    eAutoPos_TopCenter:
      dy := -d;
    eAutoPos_CenterLeft:
      dx := d * flipx;
    eAutoPos_BottomCenter:
      dy := d;
    eAutoPos_TopLeft:
      dy := -d;
    eAutoPos_TopRight:
      dy := -d;
    eAutoPos_BottomLeft:
      dy := d;
    eAutoPos_BottomRight:
      dy := d;
  end;

  if (R = 90) or (R = 270) then
  begin
    if (autoPos = eAutoPos_TopLeft) or (autoPos = eAutoPos_BottomLeft) then
    begin
      dx := d * flipx;
    end
    else if (autoPos = eAutoPos_TopRight) or (autoPos = eAutoPos_BottomRight)
    then
    begin
      dx := -d * flipx;
    end;
  end;
  Silk.MoveByXY(dx + MilsToCoord(X_offset), dy + MilsToCoord(Y_offset));
end;

function MirrorBottomRotation(Text: IPCB_Text; Rotation: TAngle): TAngle;
begin
  result := Rotation;
  if Text.Layer = eBottomOverlay then
    result := 360 - Rotation;
end;

procedure Rotation_MatchSilk2Comp(Silk: IPCB_Text);
var
  R: Integer; // Component Rotation
begin
  R := Silk.Component.Rotation;

  if (R = 0) or (R = 180) or (R = 360) then
  begin
    Silk.Rotation := MirrorBottomRotation(Silk, 0);
  end
  else if (R = 90) or (R = 270) then
  begin
    Silk.Rotation := MirrorBottomRotation(Silk, 90);
  end;
end;

function CalculateHor(Component: IPCB_Component): Integer;
var
  CompIterator: IPCB_GroupIterator;
  Primitive: IPCB_Primitive;
  Pad: IPCB_Pad2;
  Tekst: IPCB_Text;
  OldRotation: Float;
  DictionaryX: TStringList;
  DictionaryY: TStringList;
  Line: String;
  Location: String;
  Number: String;
  i: Integer;
  Indeks: Integer;
  Num: Integer;
  MaxX: Integer;
  MaxY: Integer;
  Rectangle: TCoordRect;
  BoundRect: TCoordRect;
  X1, Y1, X2, Y2: Integer;
  X, Y: Integer;
  Temp: Integer;
  PadX: Integer;
  PadY: Integer;
  PadMaxX: Integer;
  PadMinX: Integer;
  PadMaxY: Integer;
  PadMinY: Integer;
begin
  Indeks := DictionaryCache.IndexOfName(Component.Pattern);
  if Indeks <> -1 then
  begin
    result := DictionaryCache.ValueFromIndex[Indeks];
    Exit;
  end;

  OldRotation := Component.Rotation;

  Component.BeginModify;
  Component.Rotation := 0;
  Component.EndModify;

  CompIterator := Component.GroupIterator_Create;
  CompIterator.AddFilter_ObjectSet(MkSet(ePadObject));

  DictionaryX := TStringList.Create;
  DictionaryY := TStringList.Create;

  DictionaryX.NameValueSeparator := '=';
  DictionaryY.NameValueSeparator := '=';

  MaxX := 1;
  MaxY := 1;

  Pad := CompIterator.FirstPCBObject;

  while (Pad <> nil) do
  begin
    // None ideal
    PadX := IntToStr(Trunc(CoordToMMs(Pad.X) * 100));
    PadY := IntToStr(Trunc(CoordToMMs(Pad.Y) * 100));

    if DictionaryX.Count = 0 then
    begin
      PadMinX := Pad.X;
      PadMaxX := Pad.X;
      PadMinY := Pad.Y;
      PadMaxY := Pad.Y;
    end;

    if PadMinX > Pad.X then
      PadMinX := Pad.X;
    if PadMaxX < Pad.X then
      PadMaxX := Pad.X;
    if PadMinY > Pad.Y then
      PadMinY := Pad.Y;
    if PadMaxY < Pad.Y then
      PadMaxY := Pad.Y;

    Indeks := DictionaryX.IndexOfName(PadX);

    if Indeks = -1 then
      DictionaryX.Add(PadX + '=1')
    else
    begin
      Number := DictionaryX.ValueFromIndex[Indeks];
      Num := StrToInt(Number) + 1;

      if Num > MaxX then
        MaxX := Num;

      Number := IntToStr(Num);
      DictionaryX.Put(Indeks, PadX + '=' + Number);
    end;

    Indeks := DictionaryY.IndexOfName(PadY);

    if Indeks = -1 then
      DictionaryY.Add(PadY + '=1')
    else
    begin
      Number := DictionaryY.ValueFromIndex[Indeks];
      Num := StrToInt(Number) + 1;

      if Num > MaxY then
        MaxY := Num;

      Number := IntToStr(Num);
      DictionaryY.Put(Indeks, PadY + '=' + Number);
    end;

    Pad := CompIterator.NextPCBObject;
  end;
  Component.GroupIterator_Destroy(CompIterator);

  Component.BeginModify;
  Component.Rotation := OldRotation;
  Component.EndModify;

  if MaxY > MaxX then
  begin
    // This is Horizontal component
    result := 1;
  end
  else if MaxY < MaxX then
  begin
    // This is Vertical component
    result := 0;
  end
  else
  begin
    if (PadMaxX - PadMinX) > (PadMaxY - PadMinY) then
      result := 1
    else
      result := 0;
  end;
  DictionaryCache.Add(Component.Pattern + '=' + IntToStr(result));
end;

function CalculateHor2(Component: IPCB_Component): Integer;
var
  CompIterator: IPCB_GroupIterator;
  Primitive: IPCB_Primitive;
  Pad: IPCB_Pad2;
  Tekst: IPCB_Text;
  OldRotation: Float;
  DictionaryX: TStringList;
  DictionaryY: TStringList;
  Line: String;
  Location: String;
  Number: String;
  i: Integer;
  Indeks: Integer;
  Num: Integer;
  MaxX: Integer;
  MaxY: Integer;
  Rectangle: TCoordRect;
  BoundRect: TCoordRect;
  X1, Y1, X2, Y2: Integer;
  X, Y: Integer;
  Temp: Integer;
  PadX: Integer;
  PadY: Integer;
  PadMaxX: Integer;
  PadMinX: Integer;
  PadMaxY: Integer;
  PadMinY: Integer;
  Pad1X: Integer;
  Pad1Y: Integer;
  EPS: Integer;
  Q1, Q2, Q3, Q4: Integer;
  Count: Integer;
begin
  Indeks := DictionaryCache.IndexOfName(Component.Pattern);
  if Indeks <> -1 then
  begin
    result := DictionaryCache.ValueFromIndex[Indeks];
    Exit;
  end;

  OldRotation := Component.Rotation;

  Component.BeginModify;
  Component.Rotation := 0;
  Component.EndModify;

  CompIterator := Component.GroupIterator_Create;
  CompIterator.AddFilter_ObjectSet(MkSet(ePadObject));

  DictionaryX := TStringList.Create;
  DictionaryY := TStringList.Create;

  DictionaryX.NameValueSeparator := '=';
  DictionaryY.NameValueSeparator := '=';

  MaxX := 1;
  MaxY := 1;

  Count := 0;
  Pad := CompIterator.FirstPCBObject;

  while (Pad <> nil) do
  begin
    if (Pad.Name = '1') then
    begin
      Pad1X := Pad.X;
      Pad1Y := Pad.Y;
    end;

    Count := Count + 1;
    Pad := CompIterator.NextPCBObject;
  end;

  Pad := CompIterator.FirstPCBObject;
  Q1 := 0;
  Q2 := 0;
  Q3 := 0;
  Q4 := 0;

  EPS := MMsToCoord(0.01);
  while (Pad <> nil) do
  begin
    if (Pad.Name <> '1') then
    begin
      if (Pad.X - Pad1X < EPS) and (Pad.Y - Pad1Y > -EPS) then
        Q1 := Q1 + 1;
      if (Pad.X - Pad1X > -EPS) and (Pad.Y - Pad1Y > -EPS) then
        Q2 := Q2 + 1;
      if (Pad.X - Pad1X > -EPS) and (Pad.Y - Pad1Y < EPS) then
        Q3 := Q3 + 1;
      if (Pad.X - Pad1X < EPS) and (Pad.Y - Pad1Y < EPS) then
        Q4 := Q4 + 1;
    end;

    // None ideal
    PadX := IntToStr(Trunc(CoordToMMs(Pad.X) * 100));
    PadY := IntToStr(Trunc(CoordToMMs(Pad.Y) * 100));

    if DictionaryX.Count = 0 then
    begin
      PadMinX := Pad.X;
      PadMaxX := Pad.X;
      PadMinY := Pad.Y;
      PadMaxY := Pad.Y;
    end;

    if PadMinX > Pad.X then
      PadMinX := Pad.X;
    if PadMaxX < Pad.X then
      PadMaxX := Pad.X;
    if PadMinY > Pad.Y then
      PadMinY := Pad.Y;
    if PadMaxY < Pad.Y then
      PadMaxY := Pad.Y;

    Indeks := DictionaryX.IndexOfName(PadX);

    if Indeks = -1 then
      DictionaryX.Add(PadX + '=1')
    else
    begin
      Number := DictionaryX.ValueFromIndex[Indeks];
      Num := StrToInt(Number) + 1;

      if Num > MaxX then
        MaxX := Num;

      Number := IntToStr(Num);
      DictionaryX.Put(Indeks, PadX + '=' + Number);
    end;

    Indeks := DictionaryY.IndexOfName(PadY);

    if Indeks = -1 then
      DictionaryY.Add(PadY + '=1')
    else
    begin
      Number := DictionaryY.ValueFromIndex[Indeks];
      Num := StrToInt(Number) + 1;

      if Num > MaxY then
        MaxY := Num;

      Number := IntToStr(Num);
      DictionaryY.Put(Indeks, PadY + '=' + Number);
    end;

    Pad := CompIterator.NextPCBObject;
  end;
  Component.GroupIterator_Destroy(CompIterator);

  Component.BeginModify;
  Component.Rotation := OldRotation;
  Component.EndModify;

  if (Q1 = 0) and (Q2 > 0) and (Q3 > 0) and (Q4 >= 0) then
  begin
    result := 1;
  end;
  if (Q2 = 0) and (Q1 >= 0) and (Q3 > 0) and (Q4 > 0) then
  begin
    result := 0;
  end;
  if (Q3 = 0) and (Q1 > 0) and (Q2 >= 0) and (Q4 > 0) then
  begin
    result := 1;
  end;
  if (Q4 = 0) and (Q1 > 0) and (Q2 > 0) and (Q3 >= 0) then
  begin
    result := 0;
  end;

  if (Q1 < Q4) and (Q2 < Q3) and (Q1 > 0) and (Q2 > 0) then
  begin
    result := 1;
  end;
  if (Q2 < Q1) and (Q3 < Q4) and (Q2 > 0) and (Q3 > 0) then
  begin
    result := 0;
  end;
  if (Q3 < Q2) and (Q4 < Q1) and (Q3 > 0) and (Q4 > 0) then
  begin
    result := 1;
  end;
  if (Q4 < Q3) and (Q1 < Q2) and (Q4 > 0) and (Q1 > 0) then
  begin
    result := 0;
  end;

  if (Count = 2) then
  begin
    if (PadMaxX - PadMinX) > (PadMaxY - PadMinY) then
      result := 1
    else
      result := 0;
  end;
  DictionaryCache.Add(Component.Pattern + '=' + IntToStr(result));
end;

procedure Rotation_Silk(Silk: IPCB_Text; SilkscreenHor: Integer;
  NameAutoPosition: Integer);
var
  R: Integer; // Component Rotation
begin
  Case RotationStrategy of
    0:
      begin
        if (Silk.Component.Rotation = 0) or (Silk.Component.Rotation = 180) or
          (Silk.Component.Rotation = 360) then
          Silk.Rotation := MirrorBottomRotation(Silk, 0)
        else if (Silk.Component.Rotation = 90) or (Silk.Component.Rotation = 270)
        then
          Silk.Rotation := MirrorBottomRotation(Silk, 90);
      end;
    1:
      begin
        Silk.Rotation := MirrorBottomRotation(Silk, 0);
      end;
    2:
      begin
        Case NameAutoPosition of
          eAutoPos_CenterRight:
            Silk.Rotation := MirrorBottomRotation(Silk, 90);
          eAutoPos_TopCenter:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
          eAutoPos_CenterLeft:
            Silk.Rotation := MirrorBottomRotation(Silk, 90);
          eAutoPos_BottomCenter:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
          eAutoPos_TopLeft:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
          eAutoPos_TopRight:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
          eAutoPos_BottomLeft:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
          eAutoPos_BottomRight:
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
        end;
      end;
    3:
      begin
        if (Silk.Component.BoundingRectangle.Right -
          Silk.Component.BoundingRectangle.Left) >
          (Silk.Component.BoundingRectangle.Top -
          Silk.Component.BoundingRectangle.Bottom) then
          Silk.Rotation := MirrorBottomRotation(Silk, 0)
        else
          Silk.Rotation := MirrorBottomRotation(Silk, 90);
      end;
    4:
      begin
        if (SilkscreenHor = 1) then
        begin
          if (Silk.Component.Rotation = 0) or (Silk.Component.Rotation = 180) or
            (Silk.Component.Rotation = 360) then
            Silk.Rotation := MirrorBottomRotation(Silk, 0)
          else if (Silk.Component.Rotation = 90) or
            (Silk.Component.Rotation = 270) then
            Silk.Rotation := MirrorBottomRotation(Silk, 90);
        end
        else
        begin
          if (Silk.Component.Rotation = 0) or (Silk.Component.Rotation = 180) or
            (Silk.Component.Rotation = 360) then
            Silk.Rotation := MirrorBottomRotation(Silk, 90)
          else if (Silk.Component.Rotation = 90) or
            (Silk.Component.Rotation = 270) then
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
        end;
      end;
    5:
      begin
        if (SilkscreenHor = 1) then
        begin
          if (Silk.Component.Rotation = 0) or (Silk.Component.Rotation = 180) or
            (Silk.Component.Rotation = 360) then
            Silk.Rotation := MirrorBottomRotation(Silk, 0)
          else if (Silk.Component.Rotation = 90) or
            (Silk.Component.Rotation = 270) then
            Silk.Rotation := MirrorBottomRotation(Silk, 90);
        end
        else
        begin
          if (Silk.Component.Rotation = 0) or (Silk.Component.Rotation = 180) or
            (Silk.Component.Rotation = 360) then
            Silk.Rotation := MirrorBottomRotation(Silk, 90)
          else if (Silk.Component.Rotation = 90) or
            (Silk.Component.Rotation = 270) then
            Silk.Rotation := MirrorBottomRotation(Silk, 0);
        end;
      end;
  end;
end;

// Try to place one designator. Obstacles are cached once, candidate positions
// (autoposition x offset grid x shrinking size x optional altered rotation) are
// tested in memory, and only the winning position is committed with undo support.
function Place_Silkscreen(Silkscreen: IPCB_Text; MaxOffset: Integer): Boolean;
const
  OFFSET_DELTA = 5;
  // [mils] Silkscreen placement will move the position around by this delta
  MIN_SILK_SIZE = 30; // [mils]
  ABS_MIN_SILK_SIZE = 25; // [mils]
  SILK_SIZE_DELTA = 5;
  // [mils] Decrement silkscreen size by this value if not placed
var
  NextAutoP: Integer;
  xinc, yinc, xoff, yoff: Integer;
  dx, dy: TCoord;
  CandL, CandB, CandR, CandT: TCoord;
  ChosenIdx: Integer;
  SlkSize: Integer;
  i, b: Integer;
  SilkscreenHor: Integer;
  AlteredRotation: Integer;
  Rect: TCoordRect;
  CmpRect: TCoordRect;
  MaxDim, RegionExpansion: TCoord;
  CompLayerName: TPCBString;
begin
  result := False;

  // Skip hidden silkscreen
  if Silkscreen.IsHidden then
  begin
    result := True;
    Exit;
  end;

  if RotationStrategy = 4 then
    SilkscreenHor := CalculateHor(Silkscreen.Component)
  else if RotationStrategy = 5 then
    SilkscreenHor := CalculateHor2(Silkscreen.Component)
  else
    SilkscreenHor := -1;

  CompLayerName := Layer2String(Silkscreen.Component.Layer);

  // Set the initial (largest) silkscreen size before measuring the search region
  SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
  if SilkscreenIsFixedSize then
    Silkscreen.size := SilkscreenFixedSize
  else
    Silkscreen.size := MilsToCoord(SlkSize);
  if SilkscreenIsFixedWidth then
    Silkscreen.Width := SilkscreenFixedWidth
  else
    Silkscreen.Width := 2 * (Silkscreen.size / 10);

  // Cache all obstacles that any candidate position could possibly touch
  Rect := Get_Obj_Rect(Silkscreen);
  MaxDim := Rect.Right - Rect.Left;
  if (Rect.Top - Rect.Bottom) > MaxDim then
    MaxDim := Rect.Top - Rect.Bottom;
  RegionExpansion := MaxDim + SilkscreenPositionDelta +
    MilsToCoord((MaxOffset * OFFSET_DELTA) + 20);
  CmpRect := Get_Obj_Rect(Silkscreen.Component);
  Build_Obstacle_Cache(Silkscreen, CmpRect.Left - RegionExpansion,
    CmpRect.Bottom - RegionExpansion, CmpRect.Right + RegionExpansion,
    CmpRect.Top + RegionExpansion);

  For AlteredRotation := 0 to TryAlteredRotation do
  begin
    // Reset silkscreen size for this rotation attempt
    SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
    if SilkscreenIsFixedSize then
      Silkscreen.size := SilkscreenFixedSize
    else
      Silkscreen.size := MilsToCoord(SlkSize);
    if SilkscreenIsFixedWidth then
      Silkscreen.Width := SilkscreenFixedWidth
    else
      Silkscreen.Width := 2 * (Silkscreen.size / 10);

    // If not placed, reduce silkscreen size
    while (CoordToMils(Silkscreen.size) >= ABS_MIN_SILK_SIZE) or
      (SilkscreenIsFixedSize) do
    begin
      // Compute the base rectangle/anchor once per enabled autoposition. These
      // trial moves are raw (no BeginModify) since they are discarded anyway.
      BaseL.Clear;
      BaseB.Clear;
      BaseR.Clear;
      BaseT.Clear;
      BaseX.Clear;
      BaseY.Clear;
      BaseIdx.Clear;
      For i := 0 to FormCheckListBox1.Items.Count - 1 do
      begin
        if not FormCheckListBox1.Checked[i] then
          Continue;

        NextAutoP := StrToAutoPos(FormCheckListBox1.Items[i]);

        Rotation_Silk(Silkscreen, SilkscreenHor, NextAutoP);
        if AlteredRotation = 1 then
          Silkscreen.Rotation := 90 - Silkscreen.Rotation;

        Silkscreen.Component.ChangeNameAutoposition := NextAutoP;
        AutoPosDeltaAdjust(NextAutoP, 0, 0, Silkscreen, CompLayerName);

        Rect := Get_Obj_Rect(Silkscreen);
        BaseIdx.Add(IntToStr(i));
        BaseL.Add(IntToStr(Rect.Left));
        BaseB.Add(IntToStr(Rect.Bottom));
        BaseR.Add(IntToStr(Rect.Right));
        BaseT.Add(IntToStr(Rect.Top));
        BaseX.Add(IntToStr(Silkscreen.XLocation));
        BaseY.Add(IntToStr(Silkscreen.YLocation));
      end;

      // Walk the offset grid; offsets are pure translations of the base rects,
      // so each candidate is tested without touching the board.
      xoff := 0;
      For xinc := 0 to MaxOffset do
      begin
        yoff := 0;
        For yinc := 0 to MaxOffset do
        begin
          dx := MilsToCoord(xoff * OFFSET_DELTA);
          dy := MilsToCoord(yoff * OFFSET_DELTA);

          For b := 0 to BaseIdx.Count - 1 do
          begin
            // StrToInt returns clean signed integers, safe to add +/- offsets
            CandL := StrToInt(BaseL.Get(b)) + dx;
            CandB := StrToInt(BaseB.Get(b)) + dy;
            CandR := StrToInt(BaseR.Get(b)) + dx;
            CandT := StrToInt(BaseT.Get(b)) + dy;

            if Candidate_Is_Clear(CandL, CandB, CandR, CandT) then
            begin
              // PLACED: commit the winning position with proper bracketing
              ChosenIdx := StrToInt(BaseIdx.Get(b));
              NextAutoP := StrToAutoPos(FormCheckListBox1.Items[ChosenIdx]);

              Silkscreen.BeginModify;

              Rotation_Silk(Silkscreen, SilkscreenHor, NextAutoP);
              if AlteredRotation = 1 then
                Silkscreen.Rotation := 90 - Silkscreen.Rotation;

              Silkscreen.Component.ChangeNameAutoposition := NextAutoP;
              Silkscreen.MoveToXY(StrToInt(BaseX.Get(b)) + dx,
                StrToInt(BaseY.Get(b)) + dy);

              Silkscreen.EndModify;

              result := True;
              Exit;
            end;
          end;

          yoff := yoff * -1; // Toggle sign
          if yoff >= 0 then
            yoff := yoff + 1; // Toggle increment
        end;

        xoff := xoff * -1; // Toggle sign
        if xoff >= 0 then
          xoff := xoff + 1; // Toggle increment
      end;

      if SilkscreenIsFixedSize then
        Break;

      if (CoordToMils(Silkscreen.size) - SILK_SIZE_DELTA) < ABS_MIN_SILK_SIZE
      then
        Break;

      // No placement found, try reducing silkscreen size
      Silkscreen.size := Silkscreen.size - MilsToCoord(SILK_SIZE_DELTA);
      if SilkscreenIsFixedWidth then
        Silkscreen.Width := SilkscreenFixedWidth
      else
        Silkscreen.Width := Int(2 * (Silkscreen.size / 10) - 10000);
      // Width needs to change relative to size
    end;
  end;

  // Not placed: reset size and park the designator off the board
  Silkscreen.BeginModify;

  SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
  if SilkscreenIsFixedSize then
    Silkscreen.size := SilkscreenFixedSize
  else
    Silkscreen.size := MilsToCoord(SlkSize);
  if SilkscreenIsFixedWidth then
    Silkscreen.Width := SilkscreenFixedWidth
  else
    Silkscreen.Width := 2 * (Silkscreen.size / 10);

  Rotation_MatchSilk2Comp(Silkscreen);

  Silkscreen.EndModify;

  Silkscreen.BeginModify;

  Silkscreen.Component.ChangeNameAutoposition := eAutoPos_Manual;

  Silkscreen.MoveToXY(Board.XOrigin - 1000000, Board.YOrigin + 1000000);

  Silkscreen.EndModify;
end;

// Second chance for failed designators: flip rotation on squarish components,
// then retry anything left with a wider offset search grid. Designators that get
// placed here are NOT added to StillFailed, so later steps leave them alone.
function Retry_Failed(SlkList: TObjectList; StillFailed: TObjectList;
  FirstPassOffset: Integer): Integer;
const
  MAX_RATIO = 1.2;
  // Component is almost square, so we are safe to try a different rotation
  EXTENDED_OFFSET_CNT = 8; // Wider offset grid (+/- 40 mil) for stubborn parts
var
  Slk: IPCB_Text;
  Rect: TCoordRect;
  i, L, w: Integer;
  PlaceCnt: Integer;
  Rotation: Integer;
  Placed: Boolean;
begin
  PlaceCnt := 0;
  For i := 0 to SlkList.Count - 1 do
  begin
    Slk := SlkList[i];
    Placed := False;

    // Squareness of the component (not the text) decides if rotating is safe
    Rect := Get_Obj_Rect(Slk.Component);
    L := Rect.Right - Rect.Left;
    w := Rect.Top - Rect.Bottom;
    if w < L then
    begin
      w := Rect.Right - Rect.Left;
      L := Rect.Top - Rect.Bottom;
    end;

    // Silk rotations that don't match component rotations don't look right, but
    // this is less of a concern with more square components
    if (L > 0) and ((w / L) <= MAX_RATIO) then
    begin
      Rotation := Slk.Rotation;
      if (Rotation = 0) or (Rotation = 180) or (Rotation = 360) then
        Slk.Rotation := MirrorBottomRotation(Slk, 90)
      else if (Rotation = 90) or (Rotation = 270) then
        Slk.Rotation := MirrorBottomRotation(Slk, 0)
      else
        Slk.Rotation := Slk.Component.Rotation;

      if Place_Silkscreen(Slk, FirstPassOffset) then
        Placed := True
      else
        Slk.Rotation := Rotation; // Reset Original Rotation
    end;

    // Still not placed: widen the offset search grid
    if not Placed then
      Placed := Place_Silkscreen(Slk, EXTENDED_OFFSET_CNT);

    if Placed then
      Inc(PlaceCnt)
    else
      StillFailed.Add(Slk);
  end;
  result := PlaceCnt;
end;

// 2nd pass "wiggle" search: scan an expanding ring grid around every enabled
// autoposition (both rotations) and take the clear spot CLOSEST to its ideal
// position, so the wide search does not wander further than it has to.
function Wiggle_Place(Silkscreen: IPCB_Text): Boolean;
const
  WIGGLE_RADIUS_MILS = 100; // How far the grid extends from each base position
  WIGGLE_STEP_MILS = 10; // Grid pitch; coarser than the first pass offsets
  MIN_SILK_SIZE = 30; // [mils]
  ABS_MIN_SILK_SIZE = 25; // [mils]
  SILK_SIZE_DELTA = 5; // [mils]
var
  NextAutoP: Integer;
  r, xoff, yoff: Integer;
  WigSteps, Dist2: Integer;
  BestScore, BestB, BestXoff, BestYoff: Integer;
  dx, dy: TCoord;
  CandL, CandB, CandR, CandT: TCoord;
  ChosenIdx: Integer;
  SlkSize: Integer;
  i, b: Integer;
  SilkscreenHor: Integer;
  AlteredRotation: Integer;
  Rect: TCoordRect;
  CmpRect: TCoordRect;
  MaxDim, RegionExpansion: TCoord;
  CompLayerName: TPCBString;
begin
  result := False;

  if Silkscreen.IsHidden then
  begin
    result := True;
    Exit;
  end;

  if RotationStrategy = 4 then
    SilkscreenHor := CalculateHor(Silkscreen.Component)
  else if RotationStrategy = 5 then
    SilkscreenHor := CalculateHor2(Silkscreen.Component)
  else
    SilkscreenHor := -1;

  CompLayerName := Layer2String(Silkscreen.Component.Layer);
  WigSteps := WIGGLE_RADIUS_MILS div WIGGLE_STEP_MILS;

  // Set the initial (largest) silkscreen size before measuring the search region
  SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
  if SilkscreenIsFixedSize then
    Silkscreen.size := SilkscreenFixedSize
  else
    Silkscreen.size := MilsToCoord(SlkSize);
  if SilkscreenIsFixedWidth then
    Silkscreen.Width := SilkscreenFixedWidth
  else
    Silkscreen.Width := 2 * (Silkscreen.size / 10);

  // Cache all obstacles the wiggle radius could possibly reach
  Rect := Get_Obj_Rect(Silkscreen);
  MaxDim := Rect.Right - Rect.Left;
  if (Rect.Top - Rect.Bottom) > MaxDim then
    MaxDim := Rect.Top - Rect.Bottom;
  RegionExpansion := MaxDim + SilkscreenPositionDelta +
    MilsToCoord(WIGGLE_RADIUS_MILS + 20);
  CmpRect := Get_Obj_Rect(Silkscreen.Component);
  Build_Obstacle_Cache(Silkscreen, CmpRect.Left - RegionExpansion,
    CmpRect.Bottom - RegionExpansion, CmpRect.Right + RegionExpansion,
    CmpRect.Top + RegionExpansion);

  // Last-chance pass: always try the normal and the 90-flipped rotation
  For AlteredRotation := 0 to 1 do
  begin
    // Reset silkscreen size for this rotation attempt
    SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
    if SilkscreenIsFixedSize then
      Silkscreen.size := SilkscreenFixedSize
    else
      Silkscreen.size := MilsToCoord(SlkSize);
    if SilkscreenIsFixedWidth then
      Silkscreen.Width := SilkscreenFixedWidth
    else
      Silkscreen.Width := 2 * (Silkscreen.size / 10);

    while (CoordToMils(Silkscreen.size) >= ABS_MIN_SILK_SIZE) or
      (SilkscreenIsFixedSize) do
    begin
      // Base rectangle for every enabled autoposition
      BaseL.Clear;
      BaseB.Clear;
      BaseR.Clear;
      BaseT.Clear;
      BaseX.Clear;
      BaseY.Clear;
      BaseIdx.Clear;

      For i := 0 to FormCheckListBox1.Items.Count - 1 do
      begin
        if not FormCheckListBox1.Checked[i] then
          Continue;

        NextAutoP := StrToAutoPos(FormCheckListBox1.Items[i]);

        Rotation_Silk(Silkscreen, SilkscreenHor, NextAutoP);
        if AlteredRotation = 1 then
          Silkscreen.Rotation := 90 - Silkscreen.Rotation;

        Silkscreen.Component.ChangeNameAutoposition := NextAutoP;
        AutoPosDeltaAdjust(NextAutoP, 0, 0, Silkscreen, CompLayerName);

        Rect := Get_Obj_Rect(Silkscreen);
        BaseIdx.Add(IntToStr(i));
        BaseL.Add(IntToStr(Rect.Left));
        BaseB.Add(IntToStr(Rect.Bottom));
        BaseR.Add(IntToStr(Rect.Right));
        BaseT.Add(IntToStr(Rect.Top));
        BaseX.Add(IntToStr(Silkscreen.XLocation));
        BaseY.Add(IntToStr(Silkscreen.YLocation));
      end;

      // Scan rings outward; once a clear spot is found, later rings can only
      // be further away, so the search stops early on most parts
      BestScore := -1;
      BestB := -1;
      BestXoff := 0;
      BestYoff := 0;
      For r := 0 to WigSteps do
      begin
        if (BestScore >= 0) and ((r * r) >= BestScore) then
          Break;

        For xoff := -r to r do
        begin
          For yoff := -r to r do
          begin
            // Only the perimeter of ring r; inner cells were already tested
            if (Abs(xoff) <> r) and (Abs(yoff) <> r) then
              Continue;

            Dist2 := (xoff * xoff) + (yoff * yoff);
            if (BestScore >= 0) and (Dist2 >= BestScore) then
              Continue;

            dx := MilsToCoord(xoff * WIGGLE_STEP_MILS);
            dy := MilsToCoord(yoff * WIGGLE_STEP_MILS);

            For b := 0 to BaseIdx.Count - 1 do
            begin
              CandL := StrToInt(BaseL.Get(b)) + dx;
              CandB := StrToInt(BaseB.Get(b)) + dy;
              CandR := StrToInt(BaseR.Get(b)) + dx;
              CandT := StrToInt(BaseT.Get(b)) + dy;

              if Candidate_Is_Clear(CandL, CandB, CandR, CandT) then
              begin
                BestScore := Dist2;
                BestB := b;
                BestXoff := xoff;
                BestYoff := yoff;
                Break; // Earlier bases are preferred at the same offset
              end;
            end;
          end;
        end;
      end;

      if BestB >= 0 then
      begin
        // PLACED: commit the closest clear position found
        ChosenIdx := StrToInt(BaseIdx.Get(BestB));
        NextAutoP := StrToAutoPos(FormCheckListBox1.Items[ChosenIdx]);

        dx := MilsToCoord(BestXoff * WIGGLE_STEP_MILS);
        dy := MilsToCoord(BestYoff * WIGGLE_STEP_MILS);

        Silkscreen.BeginModify;

        Rotation_Silk(Silkscreen, SilkscreenHor, NextAutoP);
        if AlteredRotation = 1 then
          Silkscreen.Rotation := 90 - Silkscreen.Rotation;

        Silkscreen.Component.ChangeNameAutoposition := NextAutoP;
        Silkscreen.MoveToXY(StrToInt(BaseX.Get(BestB)) + dx,
          StrToInt(BaseY.Get(BestB)) + dy);

        Silkscreen.EndModify;

        result := True;
        Exit;
      end;

      if SilkscreenIsFixedSize then
        Break;

      if (CoordToMils(Silkscreen.size) - SILK_SIZE_DELTA) < ABS_MIN_SILK_SIZE
      then
        Break;

      // No placement found, try reducing silkscreen size
      Silkscreen.size := Silkscreen.size - MilsToCoord(SILK_SIZE_DELTA);
      if SilkscreenIsFixedWidth then
        Silkscreen.Width := SilkscreenFixedWidth
      else
        Silkscreen.Width := Int(2 * (Silkscreen.size / 10) - 10000);
    end;
  end;

  // Still not placed: reset size and park the designator off the board again
  Silkscreen.BeginModify;

  SlkSize := Get_Silk_Size(Silkscreen, MIN_SILK_SIZE);
  if SilkscreenIsFixedSize then
    Silkscreen.size := SilkscreenFixedSize
  else
    Silkscreen.size := MilsToCoord(SlkSize);
  if SilkscreenIsFixedWidth then
    Silkscreen.Width := SilkscreenFixedWidth
  else
    Silkscreen.Width := 2 * (Silkscreen.size / 10);

  Rotation_MatchSilk2Comp(Silkscreen);

  Silkscreen.EndModify;

  Silkscreen.BeginModify;

  Silkscreen.Component.ChangeNameAutoposition := eAutoPos_Manual;

  Silkscreen.MoveToXY(Board.XOrigin - 1000000, Board.YOrigin + 1000000);

  Silkscreen.EndModify;
end;

procedure RunGUI;
begin
  MEM_AllowUnder.Text := TEXTBOXINIT;
  Form_PlaceSilk.ShowModal;
end;

// Writes to the status bar at the bottom of the Altium window
procedure SetStatusBar(StatusText: String);
begin
  Client.GUIManager.StatusBar_SetState(0, StatusText);
end;

procedure AddMessage(MessageClass, MessageText: String);
begin
  // https://www.altium.com/ru/documentation/altium-nexus/wsm-api-types-and-constants/#Image%20Index%20Table
  // [!!!] 66 index for debug info
  GetWorkspace.DM_MessagesManager.BeginUpdate();
  GetWorkspace.DM_MessagesManager.AddMessage(MessageClass, MessageText,
    'Auto Place Silkscreen', GetWorkspace.DM_FocusedDocument.DM_FileName, '',
    '', 75, MessageClass = 'APS Status');
  GetWorkspace.DM_MessagesManager.EndUpdate();
  GetWorkspace.DM_MessagesManager.UpdateWindow();
end;

{ .............................................................................. }
procedure Main(Place_Selected: Boolean; Place_OverComp: Boolean;
  Place_Hide: Boolean; Place_RestoreOriginal: Boolean;
  AllowUnderList: TStringList);
const
  OFFSET_CNT = 3; // Number of attempts to offset position in x or y directions
  STATUS_INTERVAL = 10; // Update messages panel/progress every N components
var
  Silkscreen: IPCB_Text;
  Slk: IPCB_Text;
  Cmp: IPCB_Component;
  Iterator: IPCB_BoardIterator;
  Count, PlaceCnt, Pass2Cnt, i: Integer;
  NotPlaced: TObjectList;
  StillFailed: TObjectList;
  Remaining: TObjectList;
  SortedComps: TStringList;
  CmpRect: TCoordRect;
  SizeKey: Integer;
  Outline: IPCB_BoardOutline;
  vx, vy: TCoord;
  PCBSystemOptions: IPCB_SystemOptions;
  DRCSetting: Boolean;
  StartTime: TDateTime;
begin
  StartTime := Now();

  GetWorkspace.DM_MessagesManager.ClearMessages();
  GetWorkspace.DM_ShowMessageView();

  AddMessage('APS Event', 'Placing Started');
  SetStatusBar('APS: Placing silkscreen designators...');

  // Set cursor to waiting.
  Screen.Cursor := crHourGlass;

  PCBServer.PreProcess;

  // Disables Online DRC during designator movement to improve speed
  PCBSystemOptions := PCBServer.SystemOptions;

  if PCBSystemOptions <> nil then
  begin
    DRCSetting := PCBSystemOptions.DoOnlineDRC;
    PCBSystemOptions.DoOnlineDRC := False;
  end;

  TextProperites := TStringList.Create;
  TextProperites.NameValueSeparator := '=';

  DictionaryCache := TStringList.Create;
  DictionaryCache.NameValueSeparator := '=';

  // Create the obstacle/candidate caches used by Place_Silkscreen
  ObsAL := TList.Create;
  ObsAB := TList.Create;
  ObsAR := TList.Create;
  ObsAT := TList.Create;
  ObsBL := TList.Create;
  ObsBB := TList.Create;
  ObsBR := TList.Create;
  ObsBT := TList.Create;
  BaseL := TStringList.Create;
  BaseB := TStringList.Create;
  BaseR := TStringList.Create;
  BaseT := TStringList.Create;
  BaseX := TStringList.Create;
  BaseY := TStringList.Create;
  BaseIdx := TStringList.Create;

  // Board outline: candidates are polygon-tested only on non-rectangular boards
  BoardRect := Get_Obj_Rect(Board);
  BoardIsRectangular := True;
  try
    Outline := Board.BoardOutline;
    if Outline.PointCount <> 4 then
      BoardIsRectangular := False
    else
      For i := 0 to Outline.PointCount - 1 do
      begin
        if Outline.Segments[i].Kind <> ePolySegmentLine then
          BoardIsRectangular := False
        else
        begin
          vx := Outline.Segments[i].vx;
          vy := Outline.Segments[i].vy;
          if ((vx <> BoardRect.Left) and (vx <> BoardRect.Right)) or
            ((vy <> BoardRect.Bottom) and (vy <> BoardRect.Top)) then
            BoardIsRectangular := False;
        end;
      end;
  except
    BoardIsRectangular := False;
  end;

  // Unhide everything first so previously hidden designators get placed too.
  // The Hide Designator failure option still applies at the end of the run.
  if UnhideAllDesignators then
    Unhide_All_Designators(0);

  // Initialize silk reference designators to board origin coordinates.
  Move_Silk_Off_Board(Place_Selected);

  // Collect components sorted smallest-first: parts in dense clusters have the
  // fewest viable spots, so they get first pick of the free space.
  Iterator := Board.BoardIterator_Create;
  Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iterator.AddFilter_LayerSet(MkSet(eTopLayer, eBottomLayer));
  Iterator.AddFilter_Method(eProcessAll);

  SortedComps := TStringList.Create;
  Cmp := Iterator.FirstPCBObject;
  while (Cmp <> nil) do
  begin
    if (Place_Selected and Cmp.Selected) or (not(Place_Selected)) then
    begin
      CmpRect := Get_Obj_Rect(Cmp);
      SizeKey := Round(CoordToMils(CmpRect.Right - CmpRect.Left) +
        CoordToMils(CmpRect.Top - CmpRect.Bottom));
      // Fixed-width numeric key so the alphabetical sort is numeric
      SortedComps.AddObject(IntToStr(100000000 + SizeKey), Cmp);
    end;
    Cmp := Iterator.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iterator);
  SortedComps.Sort;

  NotPlaced := TObjectList.Create;
  StillFailed := TObjectList.Create;

  ProgressBar1.Position := 0;
  ProgressBar1.Max := SortedComps.Count;
  ProgressBar1.Update;

  Count := 0;
  PlaceCnt := 0;
  For i := 0 to SortedComps.Count - 1 do
  begin
    Cmp := SortedComps.Objects[i];
    Silkscreen := Cmp.Name;

    if (Place_Silkscreen(Silkscreen, OFFSET_CNT)) then
    begin
      Inc(PlaceCnt);
    end
    else
    begin
      NotPlaced.Add(Silkscreen);
    end;

    Inc(Count);

    ProgressBar1.Position := Count;
    if (Count mod STATUS_INTERVAL = 0) or (Count = SortedComps.Count) then
    begin
      ProgressBar1.Update;
      AddMessage('APS Status',
        Format('%d of %d silkscreens placed (%f%%) in %d Second(s)',
        [PlaceCnt, Count, PlaceCnt / Count * 100,
        Trunc((Now() - StartTime) * 86400)]));
      SetStatusBar(Format('APS 1st pass: %d of %d placed',
        [PlaceCnt, Count]));
    end;
  end;

  // Second pass: rotation flip for squarish components + wider offset search
  PlaceCnt := PlaceCnt + Retry_Failed(NotPlaced, StillFailed, OFFSET_CNT);

  // 2nd pass: best-fit wiggle search around every allowed position
  if WiggleEnabled and (StillFailed.Count > 0) then
  begin
    AddMessage('APS Event', Format('Running 2nd pass on %d unplaced designator(s)',
      [StillFailed.Count]));
    SetStatusBar(Format('APS 2nd pass: searching wider for %d unplaced designator(s)...',
      [StillFailed.Count]));

    ProgressBar1.Position := 0;
    ProgressBar1.Max := StillFailed.Count;
    ProgressBar1.Update;

    Pass2Cnt := 0;
    Remaining := TObjectList.Create;
    For i := 0 to StillFailed.Count - 1 do
    begin
      Slk := StillFailed[i];

      if Wiggle_Place(Slk) then
      begin
        Inc(PlaceCnt);
        Inc(Pass2Cnt);
      end
      else
        Remaining.Add(Slk);

      ProgressBar1.Position := i + 1;
      ProgressBar1.Update;
      AddMessage('APS Status',
        Format('2nd pass: %d of %d remaining designators placed in %d Second(s)',
        [Pass2Cnt, i + 1, Trunc((Now() - StartTime) * 86400)]));
      SetStatusBar(Format('APS 2nd pass: %d of %d remaining designators placed',
        [Pass2Cnt, i + 1]));
    end;
    StillFailed := Remaining;
  end;

  // Handle whatever is still unplaced per the selected failure option
  if Place_OverComp then
    Move_Silk_Over_Comp(StillFailed);
  if Place_Hide then
    Hide_Designators(StillFailed);
  if Place_RestoreOriginal then
    Restore_Comp(StillFailed);

  DictionaryCache.Free;
  TextProperites.Free;
  SortedComps.Free;

  ObsAL.Free;
  ObsAB.Free;
  ObsAR.Free;
  ObsAT.Free;
  ObsBL.Free;
  ObsBB.Free;
  ObsBR.Free;
  ObsBT.Free;
  BaseL.Free;
  BaseB.Free;
  BaseR.Free;
  BaseT.Free;
  BaseX.Free;
  BaseY.Free;
  BaseIdx.Free;

  // Restore DRC setting
  if PCBSystemOptions <> nil then
  begin
    PCBSystemOptions.DoOnlineDRC := DRCSetting;
  end;

  PCBServer.PostProcess;

  Board.ViewManager_FullUpdate;

  // Restore cursor to normal
  Screen.Cursor := crArrow;

  AddMessage('APS Event',
    Format('Placing finished with 0 contention(s). Failed to placed %d silkscreen(s) in %d Second(s)',
    [Count - PlaceCnt, Trunc((Now() - StartTime) * 86400)]));
  SetStatusBar(Format('APS: Finished. %d of %d designators placed',
    [PlaceCnt, Count]));

  if Count > 0 then
    ShowMessage('Script execution complete. ' + IntToStr(PlaceCnt) + ' out of '
      + IntToStr(Count) + ' Placed. ' + FloatToStr(Round((PlaceCnt / Count) *
      100)) + '%')
  else
    ShowMessage('Script execution complete. No components found to place.');
end;
{ .............................................................................. }

procedure Split(Delimiter: Char; Text: TPCBString; ListOfStrings: TStrings);
begin
  ListOfStrings.Clear;
  ListOfStrings.Delimiter := Delimiter;
  ListOfStrings.StrictDelimiter := True; // Requires D2006 or newer.
  ListOfStrings.DelimitedText := Text;
end;

// Unfortunately [rfReplaceAll] keeps throwing errors, so I had to write this function
function RemoveNewLines(Text: TPCBString): TPCBString;
var
  strlen: Integer;
  NewStr: TPCBString;
begin
  strlen := length(Text);
  NewStr := StringReplace(Text, NEWLINECODE, ',', rfReplaceAll);
  while length(NewStr) <> strlen do
  begin
    strlen := length(NewStr);
    NewStr := StringReplace(NewStr, NEWLINECODE, ',', rfReplaceAll);
    NewStr := StringReplace(NewStr, ' ', '', rfReplaceAll);
  end;
  result := NewStr;
end;

procedure WriteToIniFile(AFileName: String);
var
  IniFile: TIniFile;
begin
  IniFile := TIniFile.Create(AFileName);

  IniFile.WriteInteger('Window', 'Top', Form_PlaceSilk.Top);
  IniFile.WriteInteger('Window', 'Left', Form_PlaceSilk.Left);
  IniFile.WriteInteger('General', 'FilterOptions', RG_Filter.ItemIndex);
  IniFile.WriteInteger('General', 'FailedPlacementOptions',
    RG_Failures.ItemIndex);
  IniFile.WriteBool('General', 'AvoidVias', chkAvoidVias.Checked);
  IniFile.WriteInteger('General', 'RotationStrategy',
    RotationStrategyCb.ItemIndex);
  IniFile.WriteBool('General', 'TryAlteredRotation',
    TryAlteredRotationChk.Checked);
  IniFile.WriteBool('General', 'FixedSizeEnabled', FixedSizeChk.Checked);
  IniFile.WriteString('General', 'FixedSize', FixedSizeEdt.Text);
  IniFile.WriteBool('General', 'FixedWidthEnabled', FixedWidthChk.Checked);
  IniFile.WriteString('General', 'FixedWidth', FixedWidthEdt.Text);
  IniFile.WriteString('General', 'PositionDelta', PositionDeltaEdt.Text);
  IniFile.WriteBool('General', 'WiggleEnabled', WiggleChk.Checked);
  IniFile.WriteBool('General', 'UnhideAllDesignators', UnhideAllChk.Checked);

  // I know about loops, but...
  IniFile.WriteBool('General', 'Position1', PositionsClb.Checked[0]);
  IniFile.WriteBool('General', 'Position2', PositionsClb.Checked[1]);
  IniFile.WriteBool('General', 'Position3', PositionsClb.Checked[2]);
  IniFile.WriteBool('General', 'Position4', PositionsClb.Checked[3]);
  IniFile.WriteBool('General', 'Position5', PositionsClb.Checked[4]);
  IniFile.WriteBool('General', 'Position6', PositionsClb.Checked[5]);
  IniFile.WriteBool('General', 'Position7', PositionsClb.Checked[6]);
  IniFile.WriteBool('General', 'Position8', PositionsClb.Checked[7]);

  // Donts have good idea about cbCmpOutlineLayer and MEM_AllowUnder

  IniFile.Free;
end;

procedure ReadFromIniFile(AFileName: String);
var
  IniFile: TIniFile;
begin
  IniFile := TIniFile.Create(AFileName);

  Form_PlaceSilk.Top := IniFile.ReadInteger('Window', 'Top',
    Form_PlaceSilk.Top);
  Form_PlaceSilk.Left := IniFile.ReadInteger('Window', 'Left',
    Form_PlaceSilk.Left);

  RG_Filter.ItemIndex := IniFile.ReadInteger('General', 'FilterOptions',
    RG_Filter.ItemIndex);
  RG_Failures.ItemIndex := IniFile.ReadInteger('General',
    'FailedPlacementOptions', RG_Failures.ItemIndex);
  chkAvoidVias.Checked := IniFile.ReadBool('General', 'AvoidVias',
    chkAvoidVias.Checked);
  RotationStrategyCb.ItemIndex := IniFile.ReadInteger('General',
    'RotationStrategy', RotationStrategyCb.ItemIndex);
  TryAlteredRotationChk.Checked := IniFile.ReadBool('General',
    'TryAlteredRotation', TryAlteredRotationChk.Checked);
  FixedSizeChk.Checked := IniFile.ReadBool('General', 'FixedSizeEnabled',
    FixedSizeChk.Checked);
  FixedSizeEdt.Text := IniFile.ReadString('General', 'FixedSize',
    FixedSizeEdt.Text);
  FixedWidthChk.Checked := IniFile.ReadBool('General', 'FixedWidthEnabled',
    FixedWidthChk.Checked);
  FixedWidthEdt.Text := IniFile.ReadString('General', 'FixedWidth',
    FixedWidthEdt.Text);
  PositionDeltaEdt.Text := IniFile.ReadString('General', 'PositionDelta',
    PositionDeltaEdt.Text);
  WiggleChk.Checked := IniFile.ReadBool('General', 'WiggleEnabled',
    WiggleChk.Checked);
  UnhideAllChk.Checked := IniFile.ReadBool('General', 'UnhideAllDesignators',
    UnhideAllChk.Checked);

  // I know about loops, but...
  PositionsClb.Checked[0] := IniFile.ReadString('General', 'Position1',
    PositionsClb.Checked[0]);
  PositionsClb.Checked[1] := IniFile.ReadString('General', 'Position2',
    PositionsClb.Checked[1]);
  PositionsClb.Checked[2] := IniFile.ReadString('General', 'Position3',
    PositionsClb.Checked[2]);
  PositionsClb.Checked[3] := IniFile.ReadString('General', 'Position4',
    PositionsClb.Checked[3]);
  PositionsClb.Checked[4] := IniFile.ReadString('General', 'Position5',
    PositionsClb.Checked[4]);
  PositionsClb.Checked[5] := IniFile.ReadString('General', 'Position6',
    PositionsClb.Checked[5]);
  PositionsClb.Checked[6] := IniFile.ReadString('General', 'Position7',
    PositionsClb.Checked[6]);
  PositionsClb.Checked[7] := IniFile.ReadString('General', 'Position8',
    PositionsClb.Checked[7]);

  IniFile.Free;
end;

function ConfigFilename(Dummy: String = ''): String;
begin
  result := ClientAPI_SpecialFolder_AltiumApplicationData +
    '\AutoPlaceSilkscreen.ini'
end;

procedure TForm_PlaceSilk.BTN_RunClick(Sender: TObject);
var
  Place_Selected: Boolean;
  Place_OverComp: Boolean;
  Place_Hide: Boolean;
  Place_RestoreOriginal: Boolean;
  StrNoSpace: TPCBString;
  i: Integer;
  DisplayUnit: TUnit;
begin
  HintLbl.Visible := True;
  HintLbl.Update;

  MechLayerIDList.Free;

  Place_Selected := RG_Filter.ItemIndex = 1;
  Place_OverComp := RG_Failures.ItemIndex = 0;
  Place_Hide := RG_Failures.ItemIndex = 1;
  Place_RestoreOriginal := RG_Failures.ItemIndex = 2;

  AvoidVias := chkAvoidVias.Checked;

  AllowUnderList := TStringList.Create;
  if MEM_AllowUnder.Text <> TEXTBOXINIT then
  begin
    StrNoSpace := RemoveNewLines(MEM_AllowUnder.Text);
    Split(',', StrNoSpace, AllowUnderList);
  end;

  DisplayUnit := Board.DisplayUnit;
  StringToCoordUnit(PositionDeltaEdt.Text, SilkscreenPositionDelta,
    DisplayUnit);

  DisplayUnit := Board.DisplayUnit;
  StringToCoordUnit(FixedSizeEdt.Text, SilkscreenFixedSize, DisplayUnit);

  DisplayUnit := Board.DisplayUnit;
  StringToCoordUnit(FixedWidthEdt.Text, SilkscreenFixedWidth, DisplayUnit);

  SilkscreenIsFixedSize := FixedSizeChk.Checked;
  SilkscreenIsFixedWidth := FixedWidthChk.Checked;

  if TryAlteredRotationChk.Checked then
    TryAlteredRotation := 1
  else
    TryAlteredRotation := 0;

  // Pick up strategy changes made in the GUI or loaded from the ini file
  RotationStrategy := RotationStrategyCb.GetItemIndex();

  WiggleEnabled := WiggleChk.Checked;
  UnhideAllDesignators := UnhideAllChk.Checked;

  Main(Place_Selected, Place_OverComp, Place_Hide, Place_RestoreOriginal,
    AllowUnderList);

  AllowUnderList.Free;

  HintLbl.Visible := False;
  HintLbl.Update;

  Close;
end;

// When user first enters textbox, clear it
procedure TForm_PlaceSilk.MEM_AllowUnderEnter(Sender: TObject);
begin
  if MEM_AllowUnder.Text = TEXTBOXINIT then
    MEM_AllowUnder.Text := '';
end;

// New combobox item selected
procedure TForm_PlaceSilk.cbCmpOutlineLayerChange(Sender: TObject);
var
  idx: Integer;
  LayerIdx: TLayer;
  LayerObj: IPCB_LayerObject;
begin
  idx := cbCmpOutlineLayer.GetItemIndex();
  LayerObj := cbCmpOutlineLayer.Items[idx];

  LayerIdx := String2Layer(cbCmpOutlineLayer.Text);
  CmpOutlineLayerID := StrToInt(MechLayerIDList.Get(idx));
end;

procedure TForm_PlaceSilk.Form_PlaceSilkCreate(Sender: TObject);
const
  DEFAULT_CMP_OUTLINE_LAYER = 'Mechanical 13';
var
  MechIterator: IPCB_LayerObjectIterator;
  LayerObj: IPCB_LayerObject;
  idx: Integer;
begin
  // Retrieve the current board
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then
    Exit;

  MechLayerIDList := TStringList.Create;

  idx := 0;
  CmpOutlineLayerID := 0;
  MechIterator := Board.MechanicalLayerIterator;
  while MechIterator.Next do
  begin
    LayerObj := MechIterator.LayerObject;

    cbCmpOutlineLayer.AddItem(LayerObj.Name, LayerObj);
    MechLayerIDList.Add(IntToStr(LayerObj.V6_LayerID));

    // Set default layer
    if (LayerObj.Name = DEFAULT_CMP_OUTLINE_LAYER) or
      (ContainsText(LayerObj.Name, 'Component Outline')) then
    begin
      cbCmpOutlineLayer.SetItemIndex(idx);
      CmpOutlineLayerID := LayerObj.V6_LayerID;
    end;

    Inc(idx)
  end;

  RotationStrategy := RotationStrategyCb.GetItemIndex();

  PositionsClb.Items.Clear;

  PositionsClb.Items.AddObject('TopCenter', eAutoPos_TopCenter);
  PositionsClb.Items.AddObject('CenterRight', eAutoPos_CenterRight);
  PositionsClb.Items.AddObject('BottomCenter', eAutoPos_BottomCenter);
  PositionsClb.Items.AddObject('CenterLeft', eAutoPos_CenterLeft);
  PositionsClb.Items.AddObject('TopLeft', eAutoPos_TopLeft);
  PositionsClb.Items.AddObject('TopRight', eAutoPos_TopRight);
  PositionsClb.Items.AddObject('BottomLeft', eAutoPos_BottomLeft);
  PositionsClb.Items.AddObject('BottomRight', eAutoPos_BottomRight);

  PositionsClb.Checked[0] := True;
  PositionsClb.Checked[1] := True;
  PositionsClb.Checked[2] := True;
  PositionsClb.Checked[3] := True;

  FormCheckListBox1 := PositionsClb;

  HintLbl.Left := (Form_PlaceSilk.ClientWidth - HintLbl.Width) div 2;

  ReadFromIniFile(ConfigFilename);
end;

procedure TForm_PlaceSilk.Form_PlaceSilkClose(Sender: TObject;
  var Action: TCloseAction);
begin
  WriteToIniFile(ConfigFilename);
end;
