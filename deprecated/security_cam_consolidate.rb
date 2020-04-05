#!/usr/env ruby

entries = Dir.entries(Dir.pwd)
files = {}
entries.sort.each do |f|
  if f.end_with?('.out')
    parts = f.split('.')
    fh = File.open(f, 'r')
    ## Skip the first two lines of each file
    fh.readline()
    fh.readline()
    files[parts.first] = fh
  end
end

result = {}
max = {}
max_images = 0
files.each_pair do |n, fh|
  max[n] = 0
  lineno = 2
  until fh.eof?
    line = fh.readline.chomp!
    lineno += 1
    sect = line.split(':')
    raise "Bad data from #{n}.out - [#{sect.size}] - missing ':' [line: #{lineno}]" unless sect.size == 2
    images = sect.first
    data = sect.last
    result[images] = {} unless result.key?(images)
    info = result[images]
    info[n] = data
    max_images = images.length if images.length > max_images
    max[n] = data.length if data.length > max[n]
  end
end

printf "%-*s  ", max_images, 'LAST IMAGE -> NEXT IMAGE'
total_width = max_images + 1
files.each_key do |n|
  max[n] = n.length if n.length > max[n]
  printf "%-*s ", max[n], n
  total_width += max[n] + 1
end
printf "\n"
printf "-" * total_width
printf "\n"

result.each_pair do |images, info|
  printf "%-*s ", max_images, "#{images}:"
  files.each_key do |n|
    printf "%-*s ", max[n], info[n]
  end
  printf "\n"
end
