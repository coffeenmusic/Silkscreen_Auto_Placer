# Auto Place Silkscreen
Iterates through each components' silkscreen reference designator and tries to place it. It will not place over pads, component bodies, or other silkscreen. It will also not place off the board edge. The silkscreen size and width are automatically adjusted depending on the component size. If it can't find a placement, it will try reducing the size. I generally see ~95% placement on boards that aren't dense and ~80% placement on really dense boards (x86).

This script should be a good start for placement, but fine tuning will definitely need to be done after running.

## How to Run
1. Run script from pcb layout. If you want to only place selected components' silkscreen, then select these components before running the script.
2. A prompt will ask if you would like to run only on selected components (YES). NO to run on entire PCB. CANCEL to exit script.
2. Any unplaced silkscreen will be moved off the board or optionally placed on top of components. At the end a prompt will ask if you would like to place unplaced silkscreen off the board or over components.
3. A popup message box will appear on completion saying how many components were placed and what percentage were placed.

Note: May take a long time to run depending on board size, board density, & speed of computer. It took my PC 15 seconds to place 230 components and about 15 minutes to place 3000 components on a much more dense board. My PC is relatively fast, so your mileage may vary. I would recommend trying to run on selected components first and select a smaller subset to see functionality.

## Things to try in future
- Can I use clearance rules? IPCB_SilkToSilkClearanceRule
- Iterate through all good placement positions, use the one with the lowest x/y --> x2/y2 delta square distance. This will slow down execution time.
- Only allow 2 silk designators close to eachother if they are perpendicular to eachother

## Potential Issues
- I've currently only tested on a couple of boards and it works well, but issues may crop up once I've expanded testing.
- Board outline is only approximated as a Bounding Rectangle. Non rectangular boards will probably have issues.

### Useful Functions (Only used for future Altium Delphi development)
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

### Useful Links
- Zoom help: https://www.altium.com/documentation/18.0/display/ADES/PCB_Cmd-Zoom((Zoom))_AD
- Unit conversion functions and more: https://techdocs.altium.com/display/SCRT/PCB+API+Constants+and+Functions#General%20Functions