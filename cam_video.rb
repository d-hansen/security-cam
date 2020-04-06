#!/usr/bin/env ruby

require 'open3'
require 'byebug'
require 'date'

PID_video_file = '/var/run/cam_video'.freeze
CAM_root = '/data/security-cam'.freeze
LOG_vid_file = '/data/cam_video.log'.freeze

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze unless defined?(LOG_TIME_fmt)

@logout = $stdout if defined?(@logout).nil? || @logout.nil?
@logerr = $stderr if defined?(@logerr).nil? || @logerr.nil?
@logout.sync = true
@logerr.sync = true

def log_prefix
  "#{Time.now.strftime(LOG_TIME_fmt)}VP(#{@webcam})"
end

def error(msg, opts = {action: :exit})
  @logerr.puts("#{log_prefix} \e[1;33;41mERROR:\e[0m #{msg}")
  case opts[:action]
  when :exit, nil then exit 255
  when :continue then return;
  else raise "Invalid error action: #{opts[:action].inspect}, must be :exit or :continue"
  end
end
def warn(msg)
  @logerr.puts("#{log_prefix} \e[1;33;43mWARNING:\e[0m #{msg}")
end

def status(msg = '', opts = {})
  @logerr.puts("#{log_prefix} #{opts[:tag] ? "\e[30;47m#{opts[:tag]}\e[0m " : ''}#{msg}")
end

def info(msg)
  status(msg, tag: 'INFO:')
end
def notice(msg)
  status(msg, tag: 'NOTICE:')
end


## The following filter_complex could be used instead of "unsafe=1"
##cmd << "-filter_complex '[0:0]scale=w=640:h=480[i1];[1:0]scale=w=640:h=480[i2];[i1][i2]concat[v]' -map '[v]' #{mp4_path}"
#
def create_mp4(mp4_path, img_glob1, img_glob2 = nil)
  return if img_glob1.nil? && img_glob2.nil?
  cmd = "ffmpeg -y "
  cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{img_glob1}' " unless img_glob1.nil?
  cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{img_glob2}' " unless img_glob2.nil?
  cmd << "-filter_complex '[0:0][1:0]concat=unsafe=1[v]' -map '[v]' #{mp4_path}"
  stdout, stderr, status = Open3.capture3(cmd)
  if status != 0
    error("command failed (#{status})\nCMD:\t#{cmd}\nSTDERR:\t#{stderr.strip}\n")
  end
rescue Errno => ex
  error("#{ex.inspect}\n\nCMD:\t#{cmd}")
end

@webcam = nil
@webcam_dir = nil

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
        cur_date = Date::parse(ARGV.shift).to_time
      rescue => ex
        error "Invalid date format #{arg.inspect}"
      end
    when /\A-log\z/i
      @logout = @logerr = File::open(LOG_vid_file, 'a')
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

  img_dir = File::join(@webcam_dir, 'current')

  case @mode
  when :daytime
    img_glob0 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[89]*.jpg")
    img_glob1 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1*.jpg")
    mp4_date = cur_date
    mp4_time = '0800_1959'
  when :nighttime
    prev_date = cur_date - 86400
    img_glob0 = File::join(img_dir, "#{@webcam}-#{prev_date.strftime('%Y%m%d')}-2*.jpg")
    img_glob1 = File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[01234567]*.jpg")
    mp4_date = prev_date
    mp4_time = '2000_0759'
  end

  @pid_file = PID_video_file + "-#{@webcam}.pid"

  ## Make sure we aren't or have already processed this request
  if File::exist?(@pid_file)
    info = File::readlines(@pid_file)
    other_pid = info[0].to_i
    notice "Checking #{other_pid}"
    begin
      if Process.kill(0, other_pid)
        ## There's still another PID running, GTFO
        error "Other Process #{other_pid} found - exiting!"
      end
    rescue Errno::ESRCH
    end
    ## Determine if it's even time to run again
    last_date = Date::parse(info[1]).to_time
    last_mode = info[2].to_sym
    if last_date.eql?(mp4_date) && last_mode.eql?(@mode)
      error "Already packaged video for #{mp4_date} #{@mode}"
    end
    File::write(@pid_file, "#{Process.pid}\n#{mp4_date}\n#{@mode.to_s}\n")
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
  img_files.each { |img| File::delete(img) }

  notice "Done processing #{img_files.size} images into #{@mode.to_s} video!"

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

end
