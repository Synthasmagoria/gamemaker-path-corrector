## WARNING
BACK UP YOUR PROJECT BEFORE USING THIS TOOL!
It will change folder- and filenames in your project directory.

## Build instructions
Make sure that Zig is installed on your computer
After that: `zig build run`
The program will appear in zig-out/bin/

## --- GAMEMAKER PATH CORRECTOR ---
Usage: gamemaker-path-corrector < absolute project path >

Example: gamemaker-path-corrector "C:\repos\gamemaker-project\gamemaker-project.yyp"

If on windows, make sure that case sensitivity is turned on for project folder
https://learn.microsoft.com/en-us/windows/wsl/case-sensitivity#change-the-case-sensitivity-of-files-and-directories

## Windows -> Linux/MacOS compatibility guide
You may use this tool on Windows in order to make a GameMaker project that has been developed in Windows possible to continue on Linux or MacOS.
In order to do so you'll want to enable case sensitivity for the folder your project is contained in.
But you cannot enable case sensitivity in a non-empty folder.
There are two options:
1) Take all the files out of the project folder -> change case-sensitivity -> put them back in
2) Create a case sensitive folder -> put project files into folder

Then use the tool on the folder.
If you're not on Windows then the tool should work fine without any changes to your filesystem.

## Limitations
Cannot merge folders with the same name.
e.g. sprites/sprPlayerIdle & sprites/sprplayeridle
In the case of folders with the same name like this the tool will spit out a list of errors and you'll have to rename manually.

## Feature requests
The tool hasn't currently been tested on a lot of projects.
So if it doesn't manage to rename something in your project as you might expect,
then feel free to contact me on Discord (synthasmagoria).
I might update the tool to meet your needs.

## Tested versions
- IDE v2024.13.1.242
- IDE v2024.1400.0.874

## Dependencies
This library uses ZPL for JSON5 parsing.
https://github.com/zpl-c/zpl/tree/master
