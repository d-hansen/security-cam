#!/usr/bin/env ruby

require 'open3'
require 'byebug'
require 'date'

CAM_root = '/data/security-cam'.freeze

@logout = $stdout
@logerr = $stderr

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze

def log_prefix
  "#{Time.now.strftime(LOG_TIME_fmt)}(#{@webcam})"
end

def error(msg, opts = {action: :exit})
  @logerr.puts("#{log_prefix} \e[1;33;41mERROR:\e[0m #{msg}")
  case opts[:action]
  when :exit, nil then exit 255
  when :continue then return;
  else raise "Invalid error action: #{opts[:action].inspect}, must be :exit or :continue"
  end
end


def create_mp4(mp4_path, img_glob1, img_glob2 = nil)
  return if img_glob1.nil? && img_glob2.nil?
  cmd = "ffmpeg -y "
  cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{img_glob1}' " unless img_glob1.nil?
  cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{img_glob2}' " unless img_glob2.nil?
  ##cmd << "-filter_complex '[0:0]scale=w=640:h=480[i1];[1:0]scale=w=640:h=480[i2];[i1][i2]concat[v]' -map '[v]' #{mp4_path}"
  cmd << "-filter_complex '[0:0][1:0]concat=unsafe=1[v]' -map '[v]' #{mp4_path}"
  stdout, stderr, status = Open3.capture3(cmd)
  err = stderr.strip
  if err.size > 0 || status != 0
    error("command failed (#{status}) #{err}\n\t#{cmd}")
  end
  stdout.strip
  
rescue Errno => ex
  error("#{ex.inspect}\n\t#{cmd}")
end

@webcam = nil
@webcam_dir = nil

@logout.sync = true
@logerr.sync = true

@mode = nil

begin
  cur_date = Time.now
  while ARGV.size > 0
    arg = ARGV.shift
    case arg
    when /\A-night(?:time)?\z/i
      error "Only one mode can be specified!" unless @mode.nil?
      @mode = :nighttime
    when /\A-day(?:time)?\z/i
      error "Only one mode can be specified!" unless @mode.nil?
      @mode = :daytime
    when /\A-date\z/i
      begin
        error "Missing <date> for -date!" unless ARGV.size > 0
        cur_date = Date.parse(ARGV.shift).to_time
      rescue => ex
        error "Invalid date format #{arg.inspect}"
      end
    else
      error "Only one webcam can be monitored per invocation!" unless @webcam.nil?
      @webcam = arg
      @webcam_dir = File::join(CAM_root, @webcam)
      unless Dir::exist?(@webcam_dir)
        error "Unrecognized webcam: #{@webcam}, no associated directory found under #{CAM_root}"
      end
    end
  end
  error "Please specify mode (-daytime or -nighttime)!" if @mode.nil?
  error "Please specify webcam!" if @webcam.nil?

  img_dir = File::join(@webcam_dir, 'current.test')

  case @mode
  when :daytime
    img_glob0 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[89]*.jpg")
    img_glob1 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1*.jpg")
    mp4_date = cur_date
    mp4_time = '08:00_19:59'
  when :nighttime
    prev_date = cur_date - 86400
    img_glob0 = File::join(img_dir, "#{@webcam}-#{prev_date.strftime('%Y%m%d')}-2*.jpg")
    img_glob1 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[01234567]*.jpg")
    mp4_date = prev_date
    mp4_time = '20:00_07:59'
  end

  img_files = Dir::glob(img_glob0)
  img_glob0 = nil if img_files.empty?
  img_files1 = Dir::glob(img_glob1)
  img_glob1 = nil if img_files1.empty?
  img_files.concat(img_files1)
  img_files1 = nil

  mp4_dir = File::join(CAM_root, mp4_date.strftime('%Y'), mp4_date.strftime('%m'))
  unless Dir::exist?(mp4_dir)
    FileUtils::mkdir_p(mp4_dir)
    notice "Created directory #{mp4_dir}"                                             
  end
  mp4_path = File::join(mp4_dir, "#{@webcam}-#{mp4_date.strftime('%Y%m%d')}-#{mp4_time}.mp4")

  create_mp4(mp4_path, img_glob0, img_glob1)

  ## Remove the individual images
  ##img_files.each { |img| File::delete(img) }

  puts "Done!"

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

end
