// How to use:
//     1) Turn off single layer mode. SHIFT + s until you can see multiple layers.
//     2) Verify Board view is not flipped.
//     3) From PCB window, click DXP toolbar: DXP-->Run Script...-->Select 'Iterate Component Silkscreen'--> OK


//TODO: Fix Layer Filter
Uses
  Winapi, ShellApi, Win32.NTDef, Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs, System;

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
    if ObjID = eComponentObject then
    begin
        Rect := Obj.BoundingRectangleNoNameComment;
    end
    else
    begin
        Rect := Obj.BoundingRectangle;
    end;

    result := Rect;
end;

// Checks if 2 objects are overlapping on the PCB
function Is_Overlapping(Obj1: IPCB_ObjectClass, Obj2: IPCB_ObjectClass): Boolean;
const
    PAD = 10000; // Allowed Overlap = 1 mil
var
    Rect1, Rect2    : TCoordRect;
    L, R, T, B  : Integer;
    L2, R2, T2, B2  : Integer;
    Name : TPCBString;
    Hidden : Boolean;
    OverX, OverY : Boolean;
    Layer1, Layer2 : TPCBString;
begin
    Name := Obj2.Identifier;
    Hidden := Obj2.IsHidden;
    Layer1 := Layer2String(Obj1.Layer);
    Layer2 := Layer2String(Obj2.Layer);
    Obj2.Selected := True;

    // If object equals itself, return False
    if (Obj1.ObjectId = Obj2.ObjectId) and (Obj1.ObjectId = eTextObject) then
    begin
        if Obj1.Identifier = Obj2.Identifier then
        begin
            result := False; Exit; // Continue
        end;
    end;
    // Continue if Hidden
    If Obj1.IsHidden or Obj2.IsHidden Then
    Begin
        result := False; Exit; // Continue
    End;
    // Continue if Layers Dont Match
    if Layer1 = 'Top Overlay' then
    begin
       if (Layer2 <> 'Top Layer') and (Layer2 <> 'Top Overlay') then
       begin
          result := False; Exit; // Continue
       end;
    end;
    if Layer1 = 'Bottom Overlay' then
    begin
       if (Layer2 <> 'Bottom Layer') and (Layer2 <> 'Bottom Overlay') then
       begin
          result := False; Exit; // Continue
       end;
    end;



    Rect1 := Get_Obj_Rect(Obj1);
    Rect2 := Get_Obj_Rect(Obj2);

    // Get Bounding Area For Both Objects
    L := Rect1.Left + PAD;
    R := Rect1.Right - PAD;
    T := Rect1.Top - PAD;
    B := Rect1.Bottom + PAD;

    L2 := Rect2.Left;
    R2 := Rect2.Right;
    T2 := Rect2.Top;
    B2 := Rect2.Bottom;

    // Overlap in X direction
    //if ((L > L2) and (L < R2)) or ((L2 > L) and (L2 < R)) or ((R < R2) and (R > L2)) or ((R2 < R) and (R2 > L)) then
    //begin
    //    OverX := True;
    //end;
    // Overlap in Y direction
    //if ((B > B2) and (B < T2)) or ((B2 > B) and (B2 < T)) or ((T < T2) and (T > B2)) or ((T2 < T) and (T2 > B)) then
    //begin
    //    OverY := True;
    //end;
    // Must Overlap in both directions for true overlap
    //if OverX and OverY then
    //begin
    //    result := True; Exit; // Equivalent to return in C
    //end;
    if (B > T2) or (T < B2) or (L > R2) or (R < L2) then
    begin
         Obj2.Selected := False;
        result := False; Exit; // Equivalent to return in C
    end;
    Obj1.Selected := False;
    Obj2.Selected := True;
    result := True;
end;

// Get pads for surrounding area
function GetSilkAroundComponent(Board: IPCB_Board, Dataset: TStringList, Cmp: IPCB_Component, Filter_Size: Integer): TStringList;
const
    DEL = ','; // CSV Delimeter
var
    Iterator      : IPCB_SpatialIterator;
    RectL         : TCoord;
    RectR         : TCoord;
    RectB         : TCoord;
    RectT         : TCoord;
    Cmp_Layer     : TPCBString;
    Cmp_x, Cmp_y  : Integer;
    Cmp_RefDes, Slk_RefDes    : TPCBString;
    Slk_x, Slk_y  : Integer;
    Slk           : IPCB_Text;
    SlkIsDes      : Boolean;
    Slk_Layer     : TPCBString;
    Slk_Rot       : TPCBString;
    Slk_Rect      : TCoordRect;
    Slk_L         : TPCBString;
    Slk_R         : TPCBString;
    Slk_T         : TPCBString;
    Slk_B         : TPCBString;
    Slk_H         : Boolean;
    Slk_IsDes     : Boolean;
    delta_x       : Integer;
    delta_y       : Integer;
    delta         : TPCBString;
    xorigin, yorigin : Integer;
begin
    RectL := Cmp.x - Filter_Size; // Rectangle Left Filter Starting Point
    RectR := Cmp.x + Filter_Size; // Rectangle Right Filter Stopping Point
    RectB := Cmp.y - Filter_Size; // Rectangle Bottom Filter Starting Point
    RectT := Cmp.y + Filter_Size; // Rectangle Top Filter Stopping Point

    Cmp_Layer := Layer2String(Cmp.Layer);

    Iterator := Board.SpatialIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eTextObject));
    If Cmp_Layer = 'Top Layer' Then
    Begin
        Iterator.AddFilter_LayerSet(MkSet(eTopOverlay));
    End
    Else
    Begin
        Iterator.AddFilter_LayerSet(MkSet(eBottomOverlay));
    End;
    Iterator.AddFilter_Area(RectL, RectB, RectR, RectT);

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    Slk := Iterator.FirstPCBObject;
    While Slk <> NIL Do
    Begin
        SlkIsDes := Slk.IsDesignator;
        // Skip silk for current component. Only get surrounding silkscreen
        If (Cmp.Name.Text = Slk.Text) Or Not(SlkIsDes) Then
        Begin
            Slk := Iterator.NextPCBObject;
            Continue;
        End;

        If (Slk.IsHidden) Then
        Begin
            Slk := Iterator.NextPCBObject;
            Continue;
        End;

        Slk_Layer := Layer2String(Slk.Layer);
        Slk_Rot := FloatToStr(Slk.Rotation);
        Slk_Rect := Slk.BoundingRectangle;
        Slk_L := IntToStr(Slk_Rect.Left - xorigin);
        Slk_R := IntToStr(Slk_Rect.Right - xorigin);
        Slk_T := IntToStr(Slk_Rect.Top - yorigin);
        Slk_B := IntToStr(Slk_Rect.Bottom - yorigin);

        Cmp_x := Cmp.x;
        Cmp_y := Cmp.y;
        Slk_x := Slk.XLocation;
        Slk_y := Slk.YLocation;
        delta_x := abs(Cmp.x - Slk.XLocation);
        delta_y := abs(Cmp.y - Slk.YLocation);
        delta := FloatToStr(sqrt(sqr(delta_x) + sqr(delta_y)));


        Dataset.Add(Cmp.Identifier+DEL+Slk.Component.Identifier+DEL+Slk_L+DEL+Slk_R+DEL+Slk_T+DEL+Slk_B+DEL+Slk_Rot+DEL+Slk_Layer+DEL+delta);

        Slk := Iterator.NextPCBObject;
    End;

    Client.SendMessage('PCB:RunQuery', 'Clear=True' , 255, Client.CurrentView);
    Board.BoardIterator_Destroy(Iterator);

    result := Dataset;
end;

function PadShapeToStr(iteration : Integer): TPCBString;
begin
  Case iteration of
       eNoShape : result := 'No_Shape';
       eRounded : result := 'Rounded';
       eRectangular : result := 'Rectangular';
       eOctagonal : result := 'Octagonal';
       eCircleShape : result := 'Circle_Shape';
       eArcShape : result := 'Arc_Shape';
       eTerminator : result := 'Terminator';
       eRoundRectShape : result := 'Round_Rectangular_Shape';
       eRotatedRectShape : result := 'Rotated_Rectangular_Shape';
       eRoundedRectangular : result := 'Rounded_Rectangular';
  else     result := 'Unkown';
  end;
end;

// Get pads for surrounding area
function GetPadsAroundComponent(Board: IPCB_Board, Dataset: TStringList, Cmp: IPCB_Component, Filter_Size: Integer): TStringList;
const
    DEL = ','; // CSV Delimeter
var
    Iterator      : IPCB_SpatialIterator;
    RectL         : Integer;
    RectR         : Integer;
    RectB         : Integer;
    RectT         : Integer;
    Cmp_Layer     : TPCBString;
    Pad           : IPCB_Primitive;
    Pad_Layer     : TPCBString;
    Pad_x         : TPCBString;
    Pad_y         : TPCBString;
    Pad_x_dim     : TPCBString;
    Pad_y_dim     : TPCBString;
    Pad_h         : TPCBString;
    Pad_w         : TPCBString;
    Pad_Rotation  : TPCBString;
    Pad_Rect      : TCoordRect;
    Pad_L         : TPCBString;
    Pad_R         : TPCBString;
    Pad_T         : TPCBString;
    Pad_B         : TPCBString;
    Shape         : Integer;
    XSize,YSize   : TPCBString;
    CornerRad     : TPCBString;
    X1,Y1,X2,Y2   : TCoord;
    delta_x       : Integer;
    delta_y       : Integer;
    delta         : TPCBString;
    xorigin, yorigin : Integer;
begin
    RectL := Cmp.x - Filter_Size; // Rectangle Left Filter Starting Point
    RectR := Cmp.x + Filter_Size; // Rectangle Right Filter Stopping Point
    RectB := Cmp.y - Filter_Size; // Rectangle Bottom Filter Starting Point
    RectT := Cmp.y + Filter_Size; // Rectangle Top Filter Stopping Point

    Cmp_Layer := Layer2String(Cmp.Layer);

    Iterator := Board.SpatialIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(ePadObject));
    Iterator.AddFilter_LayerSet(MkSet(eTopLayer,eBottomLayer,eMultiLayer));
    Iterator.AddFilter_Area(RectL, RectB, RectR, RectT);

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Search for component body objects and get their Name, Kind, Area and OverallHeight values
    Pad := Iterator.FirstPCBObject;
    While (Pad <> Nil) Do
    Begin
        Pad_x := IntToStr(Pad.x - xorigin);
        Pad_y := IntToStr(Pad.y - yorigin);
        Pad_h := IntToStr(Pad.TopXSize);
        Pad_w := IntToStr(Pad.TopYSize);
        Pad_Layer := Layer2String(Pad.Layer);
        Pad_Rotation := FloatToStr(Pad.Rotation);
        Pad_Rect := Pad.BoundingRectangle;
        Pad_L := IntToStr(Pad_Rect.Left - xorigin);
        Pad_R := IntToStr(Pad_Rect.Right - xorigin);
        Pad_T := IntToStr(Pad_Rect.Top - yorigin);
        Pad_B := IntToStr(Pad_Rect.Bottom - yorigin);
        Shape := Pad.TopShape; // eOctagonal, eRectangular, eRounded
        CornerRad := IntToStr(Pad.CRPercentage[Pad.Layer]);
        XSize := IntToStr(Pad.TopXSize);
        YSize := IntToStr(Pad.TopYSize);

        delta_x := abs(Cmp.x - Pad.x);
        delta_y := abs(Cmp.y - Pad.y);
        delta := FloatToStr(sqrt(sqr(delta_x) + sqr(delta_y)));

        If Cmp_Layer = 'Bottom Layer' Then
        Begin
            Pad_h := IntToStr(Pad.BotXSize);
            Pad_w := IntToStr(Pad.BotYSize);
        End;

        If (Pad_Layer = Cmp_Layer) or (Pad_Layer = 'Multi Layer') Then
        Begin
            Dataset.Add(Cmp.Identifier+DEL+Pad_x+DEL+Pad_y+DEL+Pad_L+DEL+Pad_R+DEL+Pad_T+DEL+Pad_B+DEL+
            Pad_Rotation+DEL+PadShapeToStr(Shape)+DEL+CornerRad+DEL+XSize+DEL+YSize+DEL+Cmp_Layer+DEL+delta);
        End;

        Pad := Iterator.NextPCBObject;
    End;

    Board.BoardIterator_Destroy(Iterator);

    result := Dataset;
end;

// Get tracks for surrounding area
function GetTracksAroundComponent(Board: IPCB_Board, Dataset: TStringList, Cmp: IPCB_Component, Filter_Size: Integer): TStringList;
const
    DEL = ','; // CSV Delimeter
var
    Iterator      : IPCB_SpatialIterator;
    RectL         : TCoord;
    RectR         : TCoord;
    RectB         : TCoord;
    RectT         : TCoord;
    Cmp_Layer     : TPCBString;
    Cmp_x, Cmp_y  : Integer;
    Cmp_RefDes, Slk_RefDes    : TPCBString;
    Slk_x, Slk_y  : Integer;
    Track         : IPCB_Track;
    Trk_Layer     : TPCBString;
    Trk_Rect      : TCoordRect;
    Trk_L         : TPCBString;
    Trk_R         : TPCBString;
    Trk_T         : TPCBString;
    Trk_B         : TPCBString;
    Trk_X1, Trk_X2, Trk_Y1, Trk_Y2 : TPCBString;
    Trk_W         : TPCBString;
    Trk_H         : Boolean;
    delta_x       : Integer;
    delta_y       : Integer;
    delta         : TPCBString;
    xorigin, yorigin : Integer;
begin
    RectL := Cmp.x - Filter_Size; // Rectangle Left Filter Starting Point
    RectR := Cmp.x + Filter_Size; // Rectangle Right Filter Stopping Point
    RectB := Cmp.y - Filter_Size; // Rectangle Bottom Filter Starting Point
    RectT := Cmp.y + Filter_Size; // Rectangle Top Filter Stopping Point

    Cmp_Layer := Layer2String(Cmp.Layer);
    Cmp_RefDes := Cmp.Identifier;

    Iterator := Board.SpatialIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eTrackObject));
    If Cmp_Layer = 'Top Layer' Then
    Begin
        Iterator.AddFilter_LayerSet(MkSet(eTopOverlay));
    End
    Else
    Begin
        Iterator.AddFilter_LayerSet(MkSet(eBottomOverlay));
    End;
    Iterator.AddFilter_Area(RectL, RectB, RectR, RectT);

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    Track := Iterator.FirstPCBObject;
    While Track <> NIL Do
    Begin
        Trk_Layer := Layer2String(Track.Layer);
        Trk_X1 := IntToStr(Track.x1 - xorigin);
        Trk_X2 := IntToStr(Track.x2 - xorigin);
        Trk_Y1 := IntToStr(Track.y1 - yorigin);
        Trk_Y2 := IntToStr(Track.y2 - yorigin);
        Trk_W := IntToStr(Track.Width);

        Cmp_x := Cmp.x;
        Cmp_y := Cmp.y;
        delta_x := abs(Cmp.x - Track.x1);
        delta_y := abs(Cmp.y - Track.y1);
        delta := FloatToStr(sqrt(sqr(delta_x) + sqr(delta_y)));

        // Get closer of 2 deltas
        delta_x := abs(Cmp.x - Track.x2);
        delta_y := abs(Cmp.y - Track.y2);
        If FloatToStr(sqrt(sqr(delta_x) + sqr(delta_y))) < delta Then
            delta := FloatToStr(sqrt(sqr(delta_x) + sqr(delta_y)));

        Dataset.Add(Cmp_RefDes+DEL+Trk_X1+DEL+Trk_X2+DEL+Trk_Y1+DEL+Trk_Y2+DEL+Trk_W+DEL+Trk_Layer+DEL+delta);

        Track := Iterator.NextPCBObject;
    End;
    Board.BoardIterator_Destroy(Iterator);
    result := Dataset;
end;

// Get components for surrounding area
function IsOverObj(Board: IPCB_Board, Slk: IPCB_Text, ObjID: Integer, Filter_Size: Integer): Boolean;
var
    Iterator      : IPCB_SpatialIterator;
    Obj          : IPCB_Component;
    RectL         : TCoord;
    RectR         : TCoord;
    RectB         : TCoord;
    RectT         : TCoord;
    RegIter       : Boolean;
begin
    RectL := Slk.XLocation - Filter_Size; // Rectangle Left Filter Starting Point
    RectR := Slk.XLocation + Filter_Size; // Rectangle Right Filter Stopping Point
    RectB := Slk.YLocation - Filter_Size; // Rectangle Bottom Filter Starting Point
    RectT := Slk.YLocation + Filter_Size; // Rectangle Top Filter Stopping Point


    if (ObjID = eComponentObject) then
    begin
        Iterator        := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ObjID));
        Iterator.AddFilter_IPCB_LayerSet(Slk.Component.Layer);
        Iterator.AddFilter_Method(eProcessAll);
        RegIter := True;
    end
    else
    begin
        Iterator := Board.SpatialIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ObjID));
        if (ObjID = ePadObject) then
        begin
            Iterator.AddFilter_IPCB_LayerSet(Slk.Component.Layer);
        end
        else
        begin
            Iterator.AddFilter_IPCB_LayerSet(Slk.Layer);
        end;
        Iterator.AddFilter_Area(RectL, RectB, RectR, RectT);
        RegIter := False;
    end;

    Obj := Iterator.FirstPCBObject;
    While Obj <> NIL Do
    Begin
        if Obj.ObjectId = eComponentBodyObject then
        begin
            Obj := Obj.Component;
        end;

        If Is_Overlapping(Slk, Obj) Then
        Begin
             result := True; Exit; // Equivalent to return in C
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



function AutoSave_wDial(Count: Integer, autosave_cnt: Integer, Dataset: TStringList, Slk_Data: TStringList, Pad_Data: TStringList, Trk_Data: TStringList, Cmp_Data: TStringList): Boolean;
var
   btnChoice : Integer;
begin
    result := False;
    If Count mod autosave_cnt = autosave_cnt-1 Then
    Begin
         btnChoice := messagedlg('Continue Collecting Data?', mtCustom, mbYesNoCancel, 0);
         If btnChoice = mrNo Then
            result := True;

         Dataset.SaveToFile(MACRODIR+CSVFILE);
         Slk_Data.SaveToFile(MACRODIR+SLKCSVFILE);
         Pad_Data.SaveToFile(MACRODIR+PADCSVFILE);
         Trk_Data.SaveToFile(MACRODIR+TRKCSVFILE);
         Cmp_Data.SaveToFile(MACRODIR+CMPCSVFILE);
    End;
end;

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

function Add_Cmp_Dataset_Row(Dataset:TStringList, Cmp:IPCB_Component, SlkGood: TPCBString, AutoPos:Integer, xorigin: Integer, yorigin: Integer, Filt_Size: Integer);
const
   DEL = ','; // CSV Delimeter
var
   Silkscreen    : IPCB_Text;
   CmpName       : TPCBString;
   CmpNameOn     : TPCBString;
   CmpXCoord,CmpYCoord : TPCBString;
   Cmp_Rect,Slk_Rect : TCoordRect;
   Cmp_L,Cmp_R,Cmp_T,Cmp_B : TPCBString;
   CmpRot        : TPCBString;
   SilkXCoord,SilkYCoord : TPCBString;
   Slk_L,Slk_R,Slk_T,Slk_B : TPCBString;
   SilkH         : Integer;
   SilkW         : Integer;
   SilkX,NewSilkX : Integer;
   SilkY,NewSilkY : Integer;
   SilkCentX     : Integer;
   SilkCentY     : Integer;
   SilkXStr      : TPCBString;
   SilkYStr      : TPCBString;
   SilkInv       : TPCBString;
   SilkRot       : TPCBString;
   SilkJust      : TPCBString;
   SilkHidden    : TPCBString;
   SilkMir       : TPCBString;
begin
   CmpName := Cmp.Identifier;
   CmpXCoord := IntToStr(Cmp.x - xorigin);
   CmpYCoord := IntToStr(Cmp.y - yorigin);
   CmpRot := IntToStr(Cmp.Rotation);
   Cmp_Rect := Cmp.BoundingRectangleNoNameComment;
   Cmp_L := IntToStr(Cmp_Rect.Left - xorigin);
   Cmp_R := IntToStr(Cmp_Rect.Right - xorigin);
   Cmp_T := IntToStr(Cmp_Rect.Top - yorigin);
   Cmp_B := IntToStr(Cmp_Rect.Bottom - yorigin);

   Silkscreen := Cmp.Name;
   SilkH := Silkscreen.Size;
   SilkW := Silkscreen.Width;
   SilkXCoord := IntToStr(Silkscreen.XLocation - xorigin);
   SilkYCoord := IntToStr(Silkscreen.YLocation - yorigin);
   Slk_Rect := Silkscreen.BoundingRectangle;
   Slk_L := IntToStr(Slk_Rect.Left - xorigin);
   Slk_R := IntToStr(Slk_Rect.Right - xorigin);
   Slk_T := IntToStr(Slk_Rect.Top - yorigin);
   Slk_B := IntToStr(Slk_Rect.Bottom - yorigin);
   SilkInv := BoolToStr(Silkscreen.Inverted);
   SilkRot := FloatToStr(Silkscreen.Rotation);
   SilkJust := IntToStr(Silkscreen.TTFInvertedTextJustify);
   SilkMir := BoolToStr(Silkscreen.MirrorFlag);
   SilkHidden := BoolToStr(Silkscreen.IsHidden);

   Dataset.Add(CmpName+DEL+Layer2String(Cmp.Layer)+DEL+CmpRot+DEL+Cmp_L+DEL+Cmp_R+DEL+Cmp_T+DEL+Cmp_B+DEL+SlkGood+DEL+AutoPosToStr(AutoPos)
             +DEL+SilkHidden+DEL+SilkInv+DEL+SilkRot+DEL+SilkJust+DEL+SilkMir+DEL+CmpXCoord+DEL+CmpYCoord+DEL+SilkXCoord
             +DEL+SilkYCoord+DEL+Slk_L+DEL+Slk_R+DEL+Slk_T+DEL+Slk_B+DEL+IntToStr(Silkscreen.Size)+DEL+IntToStr(Silkscreen.Width)
             +DEL+IntToStr(Filt_Size));
end;

function CharCount(const S: string): integer;
var
  i: Integer;
begin
  result := 0;
  for i := 1 to Length(S) do
    inc(result);
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
        If deltR > newFilterSize Then
            newFilterSize := deltR;
        If deltT > newFilterSize Then
            newFilterSize := deltT;
        If deltB > newFilterSize Then
            newFilterSize := deltB;
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

function AutoPosDeltaAdjust(autoPos: Integer, Silk : IPCB_Text, Layer: TPCBString,);
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

  Silk.Selected := False;
  Silk.MoveByXY(dx, dy);
  Silk.Selected := True;
end;

function MsgDialogRetIntToStr(iteration : Integer): TPCBString;
begin
  Case iteration of
       1 : result := 'OK';
       2 : result := 'CANCEL';
       3 : result := 'ABORT';
       4 : result := 'RETRY';
       5 : result := 'IGNORE';
       6 : result := 'YES';
       7 : result := 'NO';
       8 : result := 'ALL';
       9 : result := 'NOTOALL';
       10 : result := 'YESTOALL';
  else     result := 'UKNOWN';
  end;
end;

{..............................................................................}
Procedure DetectOverlap;
Const
    SKIP_HIDDEN = True;
    AUTOSAVE_CNT = 50;
Var
    Board         : IPCB_Board;
    Cmp           : IPCB_Component;
    Silkscreen    : IPCB_Text;
    Iterator      : IPCB_BoardIterator;
    ReportDocument : IServerDocument;
    Count, i, n      : Integer;
    SilkX,SilkY   : Integer;
    FilterSize,BestFilterSize,Offset : Integer;
    Dataset,Slk_Data,Pad_Data,Trk_Data,Cmp_Data,UsedCmps : TStringList;
    PrevLayer      : TV6_Layer;
    AutoP          : TTextAutoposition;
    NextAutoP      : Integer;
    usedCmp,RefDes  : TPCBString;
    xorigin, yorigin : Integer;
    Silk_Rect        : TCoordRect;
    Silk_L           : Integer;
    IsOver           : Boolean;
Begin
    // Retrieve the current board
    Board := PCBServer.GetCurrentPCBBoard;
    If Board = Nil Then Exit;

    // Create the iterator that will look for Component Body objects only
    Iterator        := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
    Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
    Iterator.AddFilter_Method(eProcessAll);

    FilterSize := MilsToCoord(400);

    //Client.SendMessage('PCB:ManageLayerSets', 'SetIndex=5' , 255, Client.CurrentView);
    //AllLayersInvisible(Board);
    //PrevLayer := String2Layer('Top Layer');

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Search for component body objects and get their Name, Kind, Area and OverallHeight values
    Cmp := Iterator.FirstPCBObject;

    While (Cmp <> Nil) Do
    Begin
        Silkscreen := Cmp.Name;
        SilkX := Silkscreen.XLocation;
        SilkY := Silkscreen.YLocation;

        //IsOver := Is_Overlapping(Silkscreen, Cmp);

        // Skip hidden silkscreen
        If Silkscreen.IsHidden Then
        Begin
            Cmp := Iterator.NextPCBObject;
            Continue;
        End;

        // Set visible layers
        //Board.LayerIsDisplayed[Cmp.Layer] := True;
        //Board.LayerIsDisplayed[Silkscreen.Layer] := True;
        //PrevLayer := SetVisibleLayerSideUp(Cmp.Layer, PrevLayer);

        BestFilterSize := GetBestCmpFilterSize(Cmp, FilterSize);

        Board.GraphicalView_ZoomOnRect(Silkscreen.XLocation-BestFilterSize,Silkscreen.YLocation+BestFilterSize,Silkscreen.XLocation+BestFilterSize,Silkscreen.YLocation-BestFilterSize);

        // Zoom To Selected Component
        //Offset := MilsToCoord(200);
        //Board.GraphicalView_ZoomOnRect(Cmp.x-BestFilterSize,Cmp.y+BestFilterSize+Offset,Cmp.x+BestFilterSize,Cmp.y-BestFilterSize+Offset);

        // Change Autoposition on Silkscreen
        For i := 0 to 8 Do
        Begin
             NextAutoP := GetNextAutoPosition(i);
             Cmp.ChangeNameAutoposition := NextAutoP;
             AutoPosDeltaAdjust(NextAutoP, Silkscreen, Layer2String(Cmp.Layer));

             //If IsOverObj(Board, Silkscreen, eTextObject, BestFilterSize) or
             //   IsOverObj(Board, Silkscreen, eTrackObject, BestFilterSize) or
             //   IsOverObj(Board, Silkscreen, eComponentObject, BestFilterSize) or
             //   IsOverObj(Board, Silkscreen, ePadObject, BestFilterSize)
             If IsOverObj(Board, Silkscreen, eComponentBodyObject, BestFilterSize)
             Then
             Begin
                 Continue;
             End
             Else
             Begin
                 Cmp := Iterator.NextPCBObject;
                 Break;
             End;
             //Pad_Data := GetPadsAroundComponent(Board, Pad_Data, Cmp, BestFilterSize);

        End;

        // Undo Autoposition Change
        //Cmp.ChangeNameAutoposition := eAutoPos_Manual;
        //Silkscreen.MoveToXY(SilkX, SilkY);

        AllLayersInvisible(Board);

        Cmp := Iterator.NextPCBObject;
    End;

    Board.BoardIterator_Destroy(Iterator);
End;
{..............................................................................}

{..............................................................................}
