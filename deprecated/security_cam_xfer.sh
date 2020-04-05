#!/bin/bash

# Some useful commands to get started with

## smbclient examples
#FILES=$(smbclient -U guest -N //R6400/shop-alley-cam -c ls 2>/dev/null | awk '/^  00626E542693\(shop-alley-cam\)_/ { print $1 }')
FILES=`/bin/ls -1 /shop-alley-cam/previous-20191111`


#smbclient -U guest -N //R6400/shop-alley-cam -c "prompt off; mget *.jpg"
#smbclient -U guest -N //R6400/shop-alley-cam -c "mkdir 20170117"
#smbclient -U guest -N //R6400/shop-alley-cam -c "rm *_100??.jpg"
#smbclient -U guest -N //R6400/shop-alley-cam -c "wdel 0x80 *_100??.jpg"

## Example filename transform
for i in ${FILES}
do
   j=${i#00626E542693(shop-alley-cam)_}
   if [[ "$j" == "$i" ]]; then continue; fi
   k=${j%.jpg}
   l=${k%_*}
   number=${k#*_*_}
   motion=${l%_*}
   datetime=${l#*_}
   date=${datetime%??????}
   time=${datetime#$date}
   echo "$i -> $number @ $date $time [$motion]"
done

## Transforming jpegs into mpeg video
#ffmpeg -f image2 -framerate 5 -pattern_type glob -i '20170116*.jpg' -pix_fmt yuv420p shop-alley-cam_20170116.mp4

## Uploading video
#curl -s -T shop-alley-cam_20170117.mp4 -u guest: ftp://r6400/shop-alley-cam/
