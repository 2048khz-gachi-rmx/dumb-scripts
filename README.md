# dumb-scripts

### opus.lua
**Run via luvit, requires ffmpeg, opusenc**  
Recursively convert all .mp3's, .wav's and .flac's into opus  
Does not delete source files; replaces output files if necessary  

input dir is cwd by default; can be specified via `-i`  
output dir is `$CWD/output` by default; can be specified via `-o`  
bitrate is 160 by default; can be specified via `-b`  
invoke dry run with `-d` if unsure  
