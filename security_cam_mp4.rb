#!/usr/bin/env ruby

require 'open3'
require 'byebug'

CAM_root = '/data/security'

@logout = $stdout
@logerr = $stderr

def create_mp4(path)
  ret = nil
  gm_cmd = "ffmpeg -framerate 5 -pattern_type glob -i '*.jpg' 
  stdout, stderr, status = Open3.capture3(gm_cmd)
  err = stderr.strip
  if err.size > 0 || status != 0
    error("#{gm_cmd}\n\tfailed #{status}: #{err}")
  end
  stdout.strip!
  if stdout =~ /Total:\s+([0-9.]+)\s+/
    begin
      ret = Float($1)
    rescue ArgumentError
      error("invalid Total diff from gm compare: #{$stdout}")
    end
  end
  ret
rescue Errno::ENOENT => e
  error("#{gm_cmd}\n\t#{e.message}")
end

@webcam = nil
@daemon = false
@quit = false

@logout.sync = true
@logerr.sync = true

entries = Dir::entries(Dir::pwd) - %w(. ..)
entries.sort!
prev_img_path = nil
PFX_sz = 'shop-alley-cam-YYYYmmdd-HHMM'.size
entries.each do |img_path|
  next unless img_path.end_with?('.jpg')
  ## Determine if this is a different enough image to keep
  if prev_img_path.nil?
    prev_img_path = img_path
  else
    diff = gm_compare(prev_img_path, img_path)
    unless diff.nil?
      if diff > 0.02
        puts "KEEP #{prev_img_path[PFX_sz..-5]} -> #{img_path[PFX_sz..-5]} = #{diff}"
        prev_img_path = img_path
      else
        puts "DROP #{prev_img_path[PFX_sz..-5]} -> #{img_path[PFX_sz..-5]} = #{diff}"
        File::delete(img_path)
      end
    end
  end
end
puts "Exiting"

#ffmpeg -f image2 -framerate 5 -pattern_type glob -i '20170116*.jpg' -pix_fmt yuv420p shop-alley-cam_20170116.mp4
#compare -metric MAE ${args} ${dir}/${cur} ${dir}/${last}
