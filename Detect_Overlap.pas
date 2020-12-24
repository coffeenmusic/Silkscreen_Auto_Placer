// How to use:
//     1) Turn off single layer mode. SHIFT + s until you can see multiple layers.
//     2) Verify Board view is not flipped.
//     3) From PCB window, click DXP toolbar: DXP-->Run Script...-->Select 'Iterate Component Silkscreen'--> OK


//TODO: - Fix Layer Filter
//      - Shorten If statements where applicable
//      - If SS outside board outline return Overlap
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
    if ObjID = eComponentObject then
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

    // If object equals itself, return False
    if (Obj1.ObjectId = Obj2.ObjectId) and (Obj1.ObjectId = eTextObject) then
    begin
         if Obj1.IsDesignator and Obj2.IsDesignator then
         begin
             if Obj1.Text = Obj2.Text then
                begin
                    result := False; Exit; // Continue
                end;
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

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    L3 := L - xorigin;
    R3 := R - xorigin;
    T3 := T - yorigin;
    B3 := B - yorigin;

    L4 := L2 - xorigin;
    R4 := R2 - xorigin;
    T4 := T2 - yorigin;
    B4 := B2 - yorigin;



    if (B > T2) or (T < B2) or (L > R2) or (R < L2) then
    begin
        result := False; Exit; // Equivalent to return in C
    end;

    Obj2.Selected := True;
    result := True;
    Rect2 := Get_Obj_Rect(Obj2);
    Obj2.Selected := False;
end;

// Returns correct layer set given the object being used
function Get_LayerSet(SlkLayer: Integer, ObjID: Integer): PAnsiChar;
var
   TopBot : Integer;
begin
     TopBot := eTopLayer;
     if Layer2String(SlkLayer) = 'Bottom Overlay' then
     begin
         TopBot := eBottomLayer;
     end;

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
    Obj          : IPCB_Component;
    RectL         : TCoord;
    RectR         : TCoord;
    RectB         : TCoord;
    RectT         : TCoord;
    RegIter       : Boolean;
    Name1, Name2 : TPCBString;
    Layer1, Layer2 : TPCBString;
begin
    RectL := Slk.XLocation - Filter_Size; // Rectangle Left Filter Starting Point
    RectR := Slk.XLocation + Filter_Size; // Rectangle Right Filter Stopping Point
    RectB := Slk.YLocation - Filter_Size; // Rectangle Bottom Filter Starting Point
    RectT := Slk.YLocation + Filter_Size; // Rectangle Top Filter Stopping Point


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

    Obj := Iterator.FirstPCBObject;
    While Obj <> NIL Do
    Begin
        // Convert ComponentBody objects to Component objects
        if Obj.ObjectId = eComponentBodyObject then
        begin
            Obj := Obj.Component;
            if Obj.Name.Layer <> Slk.Layer then
            begin
                 //Name2 := Obj.Identifier;
                 //Layer1 := Layer2String(Slk.Layer);
                 //Layer2 := Layer2String(Obj.Name.Layer);
                 Obj := Iterator.NextPCBObject;
                 Continue;
            end;
        end;

        If Is_Overlapping(Board, Slk, Obj) Then
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

  Silk.MoveByXY(dx, dy);
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
    Name : TPCBString;
    StartT, StopT, DeltaT : Integer;
Begin
    // Retrieve the current board
    Board := PCBServer.GetCurrentPCBBoard;
    If Board = Nil Then Exit;

    // Create the iterator that will look for Component Body objects only
    Iterator        := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
    //Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
    Iterator.AddFilter_LayerSet(MkSet(eTopLayer));
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

        // TODO: Automatically adjust silk size based on component size,
        //       if no placement can be made, reduce size, but have a minimum size

        Silkscreen.Selected := True;

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
        //Client.SendMessage('PCB:Zoom', 'Action=Selected' , 255, Client.CurrentView);
        //Client.SendMessage('PCB:Zoom', 'Action=Out' , 255, Client.CurrentView);
        //Client.SendMessage('PCB:Zoom', 'Action=Out' , 255, Client.CurrentView);

        // Zoom To Selected Component
        //Offset := MilsToCoord(200);
        //Board.GraphicalView_ZoomOnRect(Cmp.x-BestFilterSize,Cmp.y+BestFilterSize+Offset,Cmp.x+BestFilterSize,Cmp.y-BestFilterSize+Offset);

        // Change Autoposition on Silkscreen
        For i := 0 to 8 Do
        Begin
             StartT := GetMilliSecondTime();


             NextAutoP := GetNextAutoPosition(i);
             Cmp.ChangeNameAutoposition := NextAutoP;
             AutoPosDeltaAdjust(NextAutoP, Silkscreen, Layer2String(Cmp.Layer));

             // Component Overlap Detection
             If IsOverObj(Board, Silkscreen, eComponentBodyObject, BestFilterSize)
                //IsOverObj(Board, Silkscreen, ePadObject, BestFilterSize)
             Then
             Begin
                  StopT := GetMilliSecondTime();
                  DeltaT := StopT - StartT;
                  Continue;
             End
             // Silkscreen RefDes Overlap Detection
             Else If IsOverObj(Board, Silkscreen, eTextObject, BestFilterSize) Then
             Begin
                  Continue;
             End
             // Silkscreen Tracks Overlap Detection
             Else If IsOverObj(Board, Silkscreen, eTrackObject, BestFilterSize) Then
             Begin
                  Continue;
             End
             Else
             Begin
                 Break;
             End;
             //Pad_Data := GetPadsAroundComponent(Board, Pad_Data, Cmp, BestFilterSize);
        End;

        // Undo Autoposition Change
        //Cmp.ChangeNameAutoposition := eAutoPos_Manual;
        //Silkscreen.MoveToXY(SilkX, SilkY);
        Silkscreen.Selected := False;

        AllLayersInvisible(Board);

        Cmp := Iterator.NextPCBObject;
    End;

    Board.BoardIterator_Destroy(Iterator);
End;
{..............................................................................}

{..............................................................................}
