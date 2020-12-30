## How to Run
1. Run script from pcb layout
2. Any unplaced silkscreen will be moved off the board
3. A popup message box will appear on completion

Note: Can take a long time to run depending on size of board and speed of computer. 1500 components take about an hour to place.

## Things to try
- Can I use clearance rules? IPCB_SilkToSilkClearanceRule
- YesNoDialog: Yes for selected only and No for full board
- Just update PCBServer when silkscreen is placed? Will this speed up execution time?

## Useful Functions
- Useful functions
- Value := ConfirmNoYes('Confirm Delete');
- DisplayUnit := Board.DisplayUnit; // get the displayunit (mil,mm)
- Board.GetPcbComponentByRefDes(
- MessageDlg('File: ' + FileListBox1.Items.Strings[i] + 'not found', mtError, [mbOk], 0);
- ColorTop := Board.LayerColor[String2Layer('Top Layer')];
- Board.LayerColor[Cmp.Layer_V6] := Color(227); // Red
- Client.SendMessage('PCB:Zoom', 'Action=Selected' , 255, Client.CurrentView); // Zoom to selected
- Window_Handle := Board.PCBWindow;
- Client.SendMessage('PCB:Zoom', 'Action=Redraw' , 255, Client.CurrentView);
- RunProcess('Client:FullScreen'); // Enter Full Screen
- Board.BoardOutline.BoundingRectangle;
- AllLayers 

## Useful Links
- Zoom help: https://www.altium.com/documentation/18.0/display/ADES/PCB_Cmd-Zoom((Zoom))_AD
- Unit conversion functions and more: https://techdocs.altium.com/display/SCRT/PCB+API+Constants+and+Functions#General%20Functions