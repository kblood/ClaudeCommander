Claude Commander user-tool samples
==================================

Use these with a build that includes FEAT_TOOLS_INI, such as CCUSER.COM in the
packaged distribution.

Add lines like these to cc.ini:

[tools]
File info = TOOLSAMP\INFO.BAT Shift-F3
CRC check = TOOLSAMP\CRC.BAT Shift-F4
Hex dump = TOOLSAMP\HEX.BAT Shift-F5
Stamp now = TOOLSAMP\STAMP.BAT Shift-F7

CC runs each entry as:

  PROGRAM SELECTED-FILE

Because execution goes through COMMAND.COM /C, .BAT scripts work. The selected
file is %1 inside the batch file.
