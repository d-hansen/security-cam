#!/usr/bin/env ruby

require 'open3'
require 'time'
require 'fileutils'
##require 'byebug'

CAM_root = File::join('', 'data', 'security-cam').freeze

PID_fn = File::join('', 'var', 'run', 'cam_video').freeze
LOG_fn = File::join(CAM_root, 'logs', 'cam_video.log').freeze

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze unless defined?(LOG_TIME_fmt)

@logout = $stdout if defined?(@logout).nil? || @logout.nil?
@logerr = $stderr if defined?(@logerr).nil? || @logerr.nil?
@logout.sync = true
@logerr.sync = true

def log_prefix
  "#{Time.now.strftime(LOG_TIME_fmt)}CV(#{@webcam})"
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

def make_path(path)
  unless Dir::exist?(path)
    FileUtils::mkdir_p(path) 
    notice "Created directory #{path}"
  end
  path
end

def set_compilation(mode)
  error "Only one compilation mode can be specified!" unless @mode.nil?
  @mode = mode
end

@webcam = nil
@mode = nil

begin
  open_log_file = false
  cur_date = Time.now
  while ARGV.size > 0
    arg = ARGV.shift
    case arg
    when /\A-night(?:time)?\z/i
      set_compilation(:night)
    when /\A-day(?:time)?\z/i
      set_compilation(:day)
    when /\A-morning\z/i
      set_compilation(:morning)
    when /\A-afternoon\z/i
      set_compilation(:afternoon)
    when /\A-evening\z/i
      set_compilation(:evening)
    when /\A-current\z/i
      set_compilation(:current)
    when /\A-append\z/i
      ## After creating a current compilation, append it to existing video

    when /\A-date\z/i
      begin
        error "Missing <date> for -date!" unless ARGV.size > 0
        cur_date = Time::parse(ARGV.shift)
      rescue => ex
        error "Invalid date format #{arg.inspect}"
      end
    when /\A-log\z/i
      open_log_file = true
    else
      error "Only one webcam can be monitored per invocation!" unless @webcam.nil?
      @webcam = arg
      img_dir = File::join(CAM_root, 'images', @webcam)
      unless Dir::exist?(img_dir)
        error "Unrecognized webcam: #{@webcam}, no associated directory found under #{CAM_root}"
      end
    end
  end
  error "Please specify mode (-day or -night)!" if @mode.nil?
  error "Please specify webcam!" if @webcam.nil?

  @logout = @logerr = File::open(LOG_fn, 'a') if open_log_file

  mp4_date = cur_date
  img_globs = []
  case @mode
  when :current
    img_globs.push(File::join(img_dir, "*.jpg"))
  when :morning
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[789]*.jpg"))
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1[01]*.jpg"))
  when :afternoon
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1[23456]*.jpg"))
  when :evening
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1[789]*.jpg"))
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-2[01]*.jpg"))
  when :day
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[789]*.jpg"))
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-1*.jpg"))
  when :night
    prev_date = cur_date - 86400
    img_globs.push(File::join(img_dir, "#{@webcam}-#{prev_date.strftime('%Y%m%d')}-2*.jpg"))
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-0[0123456]*.jpg"))
    mp4_date = prev_date
  end

  @pid_fn = PID_fn + "-#{@webcam}.pid"

  ## Make sure we aren't or have already processed this same request
  if File::exist?(@pid_fn)
    info = File::readlines(@pid_fn)
    other_pid = info[0].to_i
    notice "Checking #{other_pid}"
    begin
      if Process.kill(0, other_pid)
        ## There's still another PID running, GTFO
        error "Other Process #{other_pid} found - exiting!"
      end
    rescue Errno::ESRCH
    end
  end

  ## Move the set of images into a "processing" directory
  ## Alsoo calculate a time range of files we are going to be picking up
  mp4_img_dir = make_path(File::join(img_dir, "video_prefab-#{cur_date.strftime('%Y%m%d%H%M%S')}"))
  mp4_start_time = mp4_end_time = nil
  mp4_img_paths = []
  img_globs.each do |img_glob|
    img_paths = Dir::glob(img_glob)
    img_paths.each do |img_path|
      img_file = File::basename(img_path)
      mp4_img_path = File::join(mp4_img_dir, img_file)
      File::rename(img_path, mp4_img_path)
      mp4_img_paths.push(mp4_img_path)
      if img_file =~ /\A#{@webcam}-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})_(\d{3}).jpg\z/
        img_time = Time::new($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}.#{$7}".to_f)
      else
        warn "Unrecognized image filename format: #{img_file}"
        next
      end
      mp4_start_time = img_time if mp4_start_time.nil? || img_time < mp4_start_time
      mp4_end_time = img_time if mp4_end_time.nil? || img_time > mp4_end_time
    end
  end
  mp4_img_glob = File::join(mp4_img_dir, '*.jpg')

  mp4_time = "#{mp4_start_time.strftime('%H%M')}_#{mp4_end_time.strftime('%H%M')}"

  File::write(@pid_fn, "#{Process.pid}\n#{@mode.to_s}\n#{mp4_date}-#{mp4_time}\n")

  mp4_dir = make_path(File::join(CAM_root, 'video', mp4_date.strftime('%Y'), mp4_date.strftime('%m')))
  mp4_path = File::join(mp4_dir, "#{@webcam}-#{mp4_date.strftime('%Y%m%d')}-#{mp4_time}.mp4")

  begin
    cmd = "ffmpeg "
    cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{mp4_img_glob}' "
    cmd << "-movflags +faststart #{mp4_path}"
    stdout, stderr, status = Open3.capture3(cmd)
    if status != 0
      error("command failed (#{status})\nCMD:\t#{cmd}\nSTDOUT:\t#{stdout.strip}\nSTDERR:\t#{stderr.strip}\n")
    end
  rescue Errno => ex
    error("#{ex.inspect}\n\nCMD:\t#{cmd}")
  end

=begin
  ## For later, when we want to append video's together
  cmd = "ffmpeg "
  cmd << "-i #{orig_video} -i #{add_video} "
  cmd << "-filter_complex '[0:0][1:0]concat=unsafe=1[v]' -map '[v]' "
  cmd << "-movflags +faststart #{new_video}"
=end

  ## Remove the processed images
  mp4_img_paths.each { |img_path| File::delete(img_path) }
  Dir::delete(mp4_img_dir)

  notice "Done processing #{mp4_img_paths.size} images into #{@mode.to_s} video!"

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

end
