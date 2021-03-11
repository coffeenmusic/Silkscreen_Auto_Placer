object Form_PlaceSilk: TForm_PlaceSilk
  Left = 0
  Top = 0
  Caption = 'Silkscreen Auto Placer'
  ClientHeight = 471
  ClientWidth = 586
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  PixelsPerInch = 96
  TextHeight = 13
  object RG_Filter: TRadioGroup
    Left = 16
    Top = 16
    Width = 149
    Height = 72
    Caption = 'Filter Options'
    ItemIndex = 0
    Items.Strings = (
      'Place Entire Board'
      'Place Selected')
    TabOrder = 0
  end
  object RG_Failures: TRadioGroup
    Left = 16
    Top = 95
    Width = 185
    Height = 73
    Caption = 'Failed Placement Options'
    ItemIndex = 0
    Items.Strings = (
      'Center Over Components'
      'Place Off Board (Bottom Left)')
    TabOrder = 3
  end
  object GB_AllowUnder: TGroupBox
    Left = 216
    Top = 16
    Width = 320
    Height = 336
    Caption = 'Allow Silk Under Specified Components'
    TabOrder = 1
  end
  object SG_AllowUnder: TStringGrid
    Left = 229
    Top = 39
    Width = 283
    Height = 273
    Hint = 'Add Component Reference Designators'
    ColCount = 1
    DefaultColWidth = 256
    FixedCols = 0
    RowCount = 25
    TabOrder = 2
    ColWidths = (
      256)
    RowHeights = (
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24
      24)
  end
  object BTN_Run: TButton
    Left = 455
    Top = 423
    Width = 75
    Height = 25
    Caption = 'Run'
    TabOrder = 4
    OnClick = BTN_RunClick
  end
end
