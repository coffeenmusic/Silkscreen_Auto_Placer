// How to use:
//     1) Turn off single layer mode. SHIFT + s until you can see multiple layers.
//     2) Verify Board view is not flipped.
//     3) From PCB window, click DXP toolbar: DXP-->Run Script...-->Select 'Iterate Component Silkscreen'--> OK

// HALT EXECUTION: ctrl + PauseBreak

//TODO:
//      - Iterate through all good placement positions, use the one with the lowest x/y --> x2/y2 delta square distance
//      - Improve Get_Silk_Size function by creating equation that solves for any size
//      - Remove test code
//      - Create list of silkscreen not placed
Uses
  Winapi, ShellApi, Win32.NTDef, Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs, System, System.Diagnostics;

Const
    MACRODIR = 'C:\Users\stephen.thompson\Documents\Macros\Altium\Silk_GoodBad_Iterator_NoImage\';
    CSVFILE = 'Main_Dataset.csv';
    USEDCMPCSV = 'Cmp_Used_List.csv';
    SLKCSVFILE = 'Slk_Dataset.csv';
    PADCSVFILE = 'Pad_Dataset.csv';
    TRKCSVFILE = 'Trk_Dataset.csv';
    CMPCSVFILE = 'Cmp_Dataset.csv';

// May want different Bounding Rectangles depending on the object
function Get_Obj_Rect(Obj: IPCB_ObjectClass): TCoordRect;
var
    Rect    : TCoordRect;
    ObjID : Integer;
begin
    ObjID := Obj.ObjectId;
    if ObjID = eBoardObject then
    begin
        Rect := Obj.BoardOutline.BoundingRectangle;
    end
    else if ObjID = eComponentObject then
    begin
        //Rect := Obj.BoundingRectangleNoNameComment;
        Rect := Obj.BoundingRectangleNoNameCommentForSignals;
    end
    else
    begin
        Rect := Obj.BoundingRectangle;
    end;

    result := Rect;
end;

// Check if object coordinates are outside board edge
function Is_Outside_Board(Board: IPCB_Board, Obj: IPCB_ObjectClass): Boolean;
var
    BoardRect, Rect    : TCoordRect;
begin
    Rect := Get_Obj_Rect(Obj);
    BoardRect := Get_Obj_Rect(Board);

    if (Rect.Left < BoardRect.Left) or
       (Rect.Right > BoardRect.Right) or
       (Rect.Bottom < BoardRect.Bottom) or
       (Rect.Top > BoardRect.Top)
    then
    begin
         result := True;
         Exit; // return
    end;

    result := False;
end;

// Check if two layers are the on the same side of the board. Handle different layer names.
function Is_Same_Side(Layer1: Integer, Layer2: Integer): Boolean;
begin
    // Top Layer
    if (Layer1 = eTopLayer) or (Layer1 = eTopOverlay) then
    begin
        if (Layer2 <> eBottomLayer) and (Layer2 <> eBottomOverlay) then
        begin
              result := True; Exit; // return True
        end;
    end
    // Bottom Layer
    else if (Layer1 = eBottomLayer) or (Layer1 = eBottomOverlay) then
    begin
         if (Layer2 <> eTopLayer) and (Layer2 <> eTopOverlay) then
         begin
              result := True; Exit; // return True
         end;
    end
    // Multi Layer
    else if (Layer1 = eMultiLayer) or (Layer2 = eMultiLayer) then
    begin
         result := True; Exit;
    end;

    result := False;
end;

// Guess silkscreen size based on component size
function Get_Silk_Size(Slk: IPCB_Text): Integer;
var
   Rect    : TCoordRect;
   area : Integer;
begin
    // Stroke Width & Text Height
    Rect := Get_Obj_Rect(Slk.Component);
    area := CoordToMils(Rect.Right - Rect.Left)*CoordToMils(Rect.Top - Rect.Bottom);

    if area <= 10000 then
    begin
         result := 30;
         Exit;
    end
    else if area <= 25000 then
    begin
         result := 50;
         Exit;
    end
    else if area <= 100000 then
    begin
         result := 70;
         Exit;
    end;

    result := 100;
end;

// Checks if 2 objects are overlapping on the PCB
function Is_Overlapping(Board: IPCB_Board, Obj1: IPCB_ObjectClass, Obj2: IPCB_ObjectClass): Boolean;
const
    PAD = 40000; // Allowed Overlap = 4 mil
var
    Rect1, Rect2    : TCoordRect;
    L, R, T, B  : Integer;
    L2, R2, T2, B2  : Integer;
    Name1, Name2 : TPCBString;
    Hidden : Boolean;
    OverX, OverY : Boolean;
    Layer1, Layer2 : TPCBString;
    Delta1, Delta2 : Integer;
    L3, R3, T3, B3  : Integer;
    L4, R4, T4, B4  : Integer;
    xorigin, yorigin : Integer;
begin
    Name1 := Obj1.Identifier;
    Name2 := Obj2.Identifier;
    Hidden := Obj2.IsHidden;
    Layer1 := Layer2String(Obj1.Layer);
    Layer2 := Layer2String(Obj2.Layer);

    if (Obj1.ObjectId = eTextObject) and (Obj2.ObjectId = eTextObject) then
    begin
         if Obj1.IsDesignator then
         begin
             if (Obj1.Text = 'C188') or (Obj2.Text = 'C188') then
             begin
                Obj2.Selected := True;
                Obj2.Selected := False;
             end;
         end;
    end;

    // If object equals itself, return False
    if (Obj1.ObjectId = Obj2.ObjectId) and (Obj1.ObjectId = eTextObject) then
    begin
         Name1 := Obj1.Text;
         Name2 := Obj2.Text;
         //Obj2.Selected := True;
         //Obj2.Selected := False;
         if Obj1.IsDesignator and Obj2.IsDesignator then
         begin
              if Obj1.Text = Obj2.Text then
              begin
                   result := False;
                   Exit; // Continue
              end;
         end;
    end;
    // Continue if Hidden
    If Obj1.IsHidden or Obj2.IsHidden Then
    Begin
        result := False;
        Exit; // Continue
    End;

    // Continue if Layers Dont Match
    if not Is_Same_Side(Obj1.Layer, Obj2.Layer) then
    begin
         result := False;
         Exit; // Continue
    end;

    Rect1 := Get_Obj_Rect(Obj1);
    Rect2 := Get_Obj_Rect(Obj2);

    Delta1 := 0; Delta2 := 0;
    if (Obj1.ObjectId = eTextObject) and Obj1.IsDesignator then Delta1 := -PAD;
    if (Obj2.ObjectId = eTextObject) and Obj2.IsDesignator then Delta2 := -PAD;

    // Get Bounding Area For Both Objects
    L := Rect1.Left - Delta1;
    R := Rect1.Right + Delta1;
    T := Rect1.Top + Delta1;
    B := Rect1.Bottom - Delta1;

    L2 := Rect2.Left - Delta2;
    R2 := Rect2.Right + Delta2;
    T2 := Rect2.Top + Delta2;
    B2 := Rect2.Bottom - Delta2;

    xorigin := Board.XOrigin; // Test Code
    yorigin := Board.YOrigin; // Test Code

    L3 := L - xorigin; // Test Code
    R3 := R - xorigin; // Test Code
    T3 := T - yorigin; // Test Code
    B3 := B - yorigin; // Test Code

    L4 := L2 - xorigin; // Test Code
    R4 := R2 - xorigin; // Test Code
    T4 := T2 - yorigin; // Test Code
    B4 := B2 - yorigin; // Test Code



    if (B > T2) or (T < B2) or (L > R2) or (R < L2) then
    begin
         result := False;
         Exit; // Equivalent to return in C
    end;

    //Obj2.Selected := True;
    result := True;
    //Rect2 := Get_Obj_Rect(Obj2);
    //Obj2.Selected := False;
end;

// Returns correct layer set given the object being used
function Get_LayerSet(SlkLayer: Integer, ObjID: Integer): PAnsiChar;
var
   TopBot : Integer;
begin
     TopBot := eTopLayer;
     if Layer2String(SlkLayer) = 'Bottom Overlay' then TopBot := eBottomLayer;

     result := MkSet(SlkLayer); // Default layer set
     if (ObjID = eComponentObject) or (ObjID = ePadObject) then
     begin
         result := MkSet(TopBot, eMultiLayer);
     end
     else if (ObjID = eComponentBodyObject) then
     begin
         result := MkSet(eMechanical3);
     end;
end;

// Get components for surrounding area
function IsOverObj(Board: IPCB_Board, Slk: IPCB_Text, ObjID: Integer, Filter_Size: Integer): Boolean;
var
    Iterator      : IPCB_SpatialIterator;
    Obj          : IPCB_ObjectClass;
    Rect : TCoordRect;
    RectL,RectR,RectB,RectT : TCoord;
    RegIter       : Boolean; // Regular Iterator
    Name1, Name2 : TPCBString;
    Layer1, Layer2 : TPCBString;
begin
    Rect := Get_Obj_Rect(Slk);
    RectL := Rect.Left - Filter_Size;
    RectR := Rect.Right + Filter_Size;
    RectT := Rect.Top + Filter_Size;
    RectB := Rect.Bottom - Filter_Size;

    // Spatial Iterators only work with Primitive Objects and not group objects like eComponentObject and dimensions
    if (ObjID = eComponentObject) then
    begin
        Iterator        := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ObjID));
        Iterator.AddFilter_IPCB_LayerSet(Get_LayerSet(Slk.Layer, ObjID));
        Iterator.AddFilter_Method(eProcessAll);
        RegIter := True;
    end
    else
    begin
        Iterator := Board.SpatialIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ObjID));
        Iterator.AddFilter_LayerSet(Get_LayerSet(Slk.Layer, ObjID));
        Iterator.AddFilter_Area(RectL, RectB, RectR, RectT);
        RegIter := False;
    end;
    Name1 := Slk.Component.Identifier;

    // Iterate through components or pads or silkscreen etc. Depends on which object is passed in.
    Obj := Iterator.FirstPCBObject;
    While Obj <> NIL Do
    Begin
        // Ignore Hidden Objects
        if Obj.IsHidden then
        begin
             Obj := Iterator.NextPCBObject;
             Continue;
        end;

        // Convert ComponentBody objects to Component objects
        if Obj.ObjectId = eComponentBodyObject then
        begin
            Obj := Obj.Component;
            if Obj.Name.Layer <> Slk.Layer then
            begin
                 Obj := Iterator.NextPCBObject;
                 Continue;
            end;
        end;

        //Obj.Selected := True;

        // Check if Silkscreen is overlapping with other object (component/pad/silk)
        If Is_Overlapping(Board, Slk, Obj) Then
        Begin
             result := True;
             Exit; // Equivalent to return in C
        End;

        Obj := Iterator.NextPCBObject;
    End;

    // Destroy Iterator
    If RegIter then
    begin
         Board.BoardIterator_Destroy(Iterator);
    end
    else
    begin
         Board.SpatialIterator_Destroy(Iterator);
    end;

    result := False;
end;

// Moves silkscreen reference designators to board origin. Used as initialization step.
function Move_Silk_Off_Board(Board: IPCB_Board);
var
    Iterator     : IPCB_SpatialIterator;
    Slk          : IPCB_Text;
begin
     Iterator        := Board.BoardIterator_Create;
     Iterator.AddFilter_ObjectSet(MkSet(eTextObject));
     Iterator.AddFilter_IPCB_LayerSet(MkSet(eTopOverlay, eBottomOverlay));
     Iterator.AddFilter_Method(eProcessAll);

    // Iterate through silkscreen reference designators.
    Slk := Iterator.FirstPCBObject;
    While Slk <> NIL Do
    Begin
         if Slk.IsDesignator then
         begin
              Slk.Component.ChangeNameAutoposition := eAutoPos_Manual;
              Slk.MoveToXY(Board.XOrigin, Board.YOrigin); // Move to board origin
              Slk.Selected := False;
         end;

         Slk := Iterator.NextPCBObject;
    End;
    Board.BoardIterator_Destroy(Iterator);
end;

// Converts position index to its string equivalent.
function AutoPosToStr(iteration : Integer): TPCBString;
begin
  Case iteration of
       eAutoPos_CenterRight : result := 'Center_Right';
       eAutoPos_TopCenter : result := 'Top_Center';
       eAutoPos_CenterLeft : result := 'Center_Left';
       eAutoPos_BottomCenter : result := 'Bottom_Center';
       eAutoPos_TopLeft : result := 'Top_Left';
       eAutoPos_TopRight : result := 'Top_Right';
       eAutoPos_BottomLeft : result := 'Bottom_Left';
       eAutoPos_BottomRight : result := 'Bottom_Right';
       eAutoPos_Manual : result := 'Manual';
  else     result := 'Unkown';
  end;
end;

function GetBestCmpFilterSize(Cmp: IPCB_Component, Filter_Size: Integer): Integer;
var
    FiltL,FiltR,FiltT,FiltB : TCoord;
    Cmp_Rect      : TCoordRect;
    CmpL,CmpR,CmpT,CmpB : Integer;
    deltL,deltR,deltT,deltB : Integer;
    newFilterSize : Integer;
begin
    newFilterSize := Filter_Size;

    FiltL := Cmp.x - Filter_Size; // Rectangle Left Filter Starting Point
    FiltR := Cmp.x + Filter_Size; // Rectangle Right Filter Stopping Point
    FiltB := Cmp.y - Filter_Size; // Rectangle Bottom Filter Starting Point
    FiltT := Cmp.y + Filter_Size; // Rectangle Top Filter Stopping Point

    Cmp_Rect := Cmp.BoundingRectangleNoNameComment;
    CmpL := Cmp_Rect.Left;
    CmpR := Cmp_Rect.Right;
    CmpT := Cmp_Rect.Top;
    CmpB := Cmp_Rect.Bottom;

    If (CmpL < FiltL) or (CmpR > FiltR) or (CmpT > FiltT) or (CmpB < FiltB) Then
    Begin
        deltL := abs(CmpL - Cmp.x);
        deltR := abs(CmpR - Cmp.x);
        deltT := abs(CmpT - Cmp.y);
        deltB := abs(CmpB - Cmp.y);

        newFilterSize := deltL;
        If deltR > newFilterSize Then newFilterSize := deltR;
        If deltT > newFilterSize Then newFilterSize := deltT;
        If deltB > newFilterSize Then newFilterSize := deltB;
        newFilterSize := newFilterSize + newFilterSize*0.05; // Add 5% border
    End;
    result := newFilterSize;
end;

// Disable visibility for all layers
function AllLayersInvisible(Board: IPCB_Board);
var
  LayerIterator : IPCB_LayerObjectIterator;
begin
  LayerIterator := Board.LayerIterator;
  While LayerIterator.Next Do
    Board.LayerIsDisplayed[LayerIterator.LayerObject.V6_LayerID] := False;
end;

// Flip Board So Visible Layer Is not Inverted
function SetVisibleLayerSideUp(CurrentLayer: TV6_Layer, PrevLayer: TV6_Layer): TV6_Layer;
begin
    If CurrentLayer <> PrevLayer Then
        Begin
            Client.SendMessage('PCB:FlipBoard', 'Action=FlipBoard' , 255, Client.CurrentView);
            PrevLayer := CurrentLayer;
        End;
    result := PrevLayer;
end;

function GetNextAutoPosition(iteration : Integer): Integer;
begin
  Case iteration of
       0 : result := eAutoPos_CenterRight;
       1 : result := eAutoPos_TopCenter;
       2 : result := eAutoPos_CenterLeft;
       3 : result := eAutoPos_BottomCenter;
       4 : result := eAutoPos_TopLeft;
       5 : result := eAutoPos_TopRight;
       6 : result := eAutoPos_BottomLeft;
       7 : result := eAutoPos_BottomRight;
       8 : result := eAutoPos_Manual;
  else     result := eAutoPos_Manual;
  end;
end;

function AutoPosDeltaAdjust(autoPos: Integer, X_offset: Integer, Y_offset: Integer, Silk : IPCB_Text, Layer: TPCBString);
const
    DELTAMILS = 20;
var
    dx,dy,d : Integer;
    xorigin, yorigin : Integer;
    flipx : Integer;
    r : Integer;
begin
  d := MilsToCoord(DELTAMILS);
  dx := 0;
  dy := 0;
  r := Silk.Rotation;
  flipx := 1; // x Direction flips on the bottom layer
  If Layer = 'Bottom Layer' Then
     flipx := -1;

  Case autoPos of
       eAutoPos_CenterRight : dx := -d*flipx;
       eAutoPos_TopCenter : dy := -d;
       eAutoPos_CenterLeft : dx := d*flipx;
       eAutoPos_BottomCenter : dy := d;
       eAutoPos_TopLeft : dy := -d;
       eAutoPos_TopRight : dy := -d;
       eAutoPos_BottomLeft : dy := d;
       eAutoPos_BottomRight : dy := d;
  end;

  If (r = 90) or (r = 270) Then
  Begin
      If (autoPos = eAutoPos_TopLeft) or (autoPos = eAutoPos_BottomLeft) Then
      Begin
          dx := d*flipx;
      End
      Else If (autoPos = eAutoPos_TopRight) or (autoPos = eAutoPos_BottomRight) Then
      Begin
          dx := -d*flipx;
      End;
  End;

  Silk.MoveByXY(dx + MilsToCoord(X_offset), dy + MilsToCoord(Y_offset));
end;

function Place_Silkscreen(Board: IPCB_Board, Silkscreen: IPCB_Text): Boolean;
const
    OFFSET_DELTA = 5; // [mils] Silkscreen placement will move the position around by this delta
    MIN_SILK_SIZE = 25; // [mils]
    FILTER_SIZE_MILS = 100; // [mils]
var
    NextAutoP      : Integer;
    Placed : Boolean;
    xinc, yinc, xoff, yoff : Integer;
    SlkSize : Integer;
    FilterSize : Integer;
    Count, i      : Integer;
begin
     result := True;
     Placed := False;

     // Skip hidden silkscreen
     If Silkscreen.IsHidden Then
     Begin
          Exit;
     End;

     FilterSize := MilsToCoord(FILTER_SIZE_MILS);

     // Get Silkscreen Size
     SlkSize := Get_Silk_Size(Silkscreen);
     Silkscreen.Size := MilsToCoord(SlkSize);
     Silkscreen.Width := 2*(Silkscreen.Size/10);

     While CoordToMils(Silkscreen.Size) > MIN_SILK_SIZE Do
     Begin
          xoff := 0;
          For xinc := 0 to 5 Do
          Begin
               yoff := 0;
               For yinc := 0 to 5 Do
               Begin
                    // Change Autoposition on Silkscreen
                    For i := 0 to 8 Do
                    Begin
                         NextAutoP := GetNextAutoPosition(i);
                         Silkscreen.Component.ChangeNameAutoposition := NextAutoP;
                         AutoPosDeltaAdjust(NextAutoP, xoff*OFFSET_DELTA, yoff*OFFSET_DELTA, Silkscreen, Layer2String(Silkscreen.Component.Layer));

                         // Component Overlap Detection
                         If IsOverObj(Board, Silkscreen, eComponentBodyObject, FilterSize) Then
                         Begin
                              Continue;
                         End
                         // Silkscreen RefDes Overlap Detection
                         Else If IsOverObj(Board, Silkscreen, eTextObject, FilterSize) Then
                         Begin
                              Continue;
                         End
                         // Silkscreen Tracks Overlap Detection
                         Else If IsOverObj(Board, Silkscreen, eTrackObject, FilterSize) Then
                         Begin
                              Continue;
                         End
                         Else If IsOverObj(Board, Silkscreen, ePadObject, FilterSize) Then
                         Begin
                              Continue;
                         End
                         // Outside Board Edge
                         Else If Is_Outside_Board(Board, Silkscreen) Then
                         Begin
                              Continue;
                         End
                         Else
                         Begin
                              Placed := True;
                              Exit;
                         End;
                    End;

                    yoff := yoff*-1; // Toggle sign
                    if yoff >= 0 then yoff := yoff + 1; // Toggle increment
               End;

               xoff := xoff*-1; // Toggle sign
               if xoff >= 0 then xoff := xoff +1; // Toggle increment
          End;

          if Placed or ((CoordToMils(Silkscreen.Size) - 5) < MIN_SILK_SIZE) then break;

          // No placement found, try reducing silkscreen size
          Silkscreen.Size := Silkscreen.Size - MilsToCoord(5);
          Silkscreen.Width := 2*(Silkscreen.Size/10) - 10000;
     End;

     if not Placed then
     begin
          // Move off board for now
          Silkscreen.Component.ChangeNameAutoposition := eAutoPos_Manual;
          Silkscreen.MoveToXY(Board.XOrigin - 500000, Board.YOrigin + 500000); // Move to board origin
     end;

     result := False;
end;

{..............................................................................}
Procedure DetectOverlap;
Var
    Board         : IPCB_Board;
    Cmp           : IPCB_Component;
    Silkscreen    : IPCB_Text;
    Iterator      : IPCB_BoardIterator;
    Count, PlaceCnt : Integer;
Begin
    // Retrieve the current board
    Board := PCBServer.GetCurrentPCBBoard;
    If Board = Nil Then Exit;

    // Initialize silk reference designators to board origin coordinates.
    Move_Silk_Off_Board(Board);

    // Create the iterator that will look for Component Body objects only
    Iterator        := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
    //Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
    //Iterator.AddFilter_LayerSet(MkSet(eTopLayer, eBottomLayer));
    Iterator.AddFilter_LayerSet(MkSet(eTopLayer));
    Iterator.AddFilter_Method(eProcessAll);

    // Search for component body objects and get their Name, Kind, Area and OverallHeight values
    Count := 0; PlaceCnt := 0; 
    Cmp := Iterator.FirstPCBObject;
    While (Cmp <> Nil) Do
    Begin

        Silkscreen := Cmp.Name;

        if (Place_Silkscreen(Board, Silkscreen)) then
        begin
            Inc(PlaceCnt);
        end;

        Inc(Count);
        Cmp := Iterator.NextPCBObject;
    End;

    Board.BoardIterator_Destroy(Iterator);
End;
{..............................................................................}

{..............................................................................}
