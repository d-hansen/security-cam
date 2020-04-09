#!/usr/bin/env ruby

require 'open3'
require 'time'
require 'fileutils'
##require 'byebug'

CAM_root = File::join('', 'data', 'security-cam').freeze

PID_fn = File::join('', 'var', 'run', 'cam_video').freeze
LOG_fn = File::join(CAM_root, 'logs', 'cam_video.log').freeze

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze unless defined?(LOG_TIME_fmt)
CONTINUE_PFX = 'continue-'.freeze
PREFAB_PFX = 'video_prefab'.freeze

VALID_MODES = {
    night:      /\A-night(?:time)?\z/i,
    day:        /\A-day(?:time)?\z/i,
    morning:    /\A-morning\z/i,
    afternoon:  /\A-afternoon\z/i,
    evening:    /\A-evening\z/i,
    all:        /\A-(?:all)|(?:current)\z/i,
    continue:   /\A-(?:continue)|(?:resume)\z/i,
    custom:     nil,    ## used if -time was given
    date:       nil,    ## maybe used if -date was given without mode
  }

$stdout.sync = true

def log_message(msg, opts = {})
  msg = "#{Time.now.strftime(LOG_TIME_fmt)}CV(#{@webcam}) #{msg}"
  @logout.puts(msg) unless @logout.nil? || opts.key?(:logout) && opts[:logout].eql?(false)
  $stdout.puts(msg) unless opts.key?(:stdout) && opts[:stdout].eql?(false)
end

def error(msg, opts = {action: :exit})
  log_message("\e[1;33;41mERROR:\e[0m #{msg}", opts)
  case opts[:action]
  when :exit, nil then exit 255
  when :continue then return;
  else raise "Invalid error action: #{opts[:action].inspect}, must be :exit or :continue"
  end
end
def warn(msg, opts = {})
  log_message("\e[1;33;43mWARNING:\e[0m #{msg}", opts)
end

def status(msg = '', opts = {})
  log_message(opts[:tag] ? "\e[30;47m#{opts[:tag]}\e[0m #{msg}" : msg, opts)
end
def info(msg, opts = {})
  status(msg, opts.merge(tag: 'INFO:'))
end
def notice(msg, opts = {})
  status(msg, opts.merge(tag: 'NOTICE:'))
end


def make_path(path)
  unless Dir::exist?(path)
    FileUtils::mkdir_p(path) 
    notice "Created directory #{path}"
  end
  path
end

def set_compilation(mode)
  error "Only one compilation mode can be specified!" unless @mode.nil? || @mode.eql?(:date)
  @mode = mode
end

def get_line(io)
  line = nil
  maybe_line_term = false
  io.each_char do |ch|
    if ch.eql?("\r")
      next if line.nil?         ##just ignore if it's the first thing encountered ('\n\r' case)
      maybe_line_term = true    ## check for '\r\n' case.
      next
    elsif maybe_line_term && !ch.eql?("\n")
      io.ungetc(ch)             ## just a plain old '\r' all by itself - we'll call that a "line"
      break
    elsif ch.eql?("\n")
      break
    end
    line = '' if line.nil?
    line << ch
  end
  line
end

@webcam = nil
@mode = nil

begin
  log_file_only = false
  custom_start = custom_stop = nil
  cur_date = Time.now
  while ARGV.size > 0
    arg = ARGV.shift
    if arg.start_with?('-')
      case arg
      when /\A-append\z/i
        ## After creating a current compilation, append it to existing video
        error "#{arg} is UNSUPPORTED AT THIS TIME!"
      when /\A-date\z/i
        begin
          error "Missing <date> for -date!" unless ARGV.size > 0
          cur_date = Time::parse(ARGV.shift)
          @mode = :date
        rescue => ex
          error "Invalid date format #{arg.inspect}"
        end
      when /\A-custom\z/i
        error "Must specify time range with -time" unless ARGV.size > 0
        time_str = ARGV.shift
        if time_str =~ /\A(\d{2}:\d{2})-(\d{2}:\d{2})\z/
          @mode = :custom
          custom_start = $1
          custom_stop = $2
        else
          error "Time range must follow <HH:MM>-<HH:MM>!"
        end
      when /\A-log(?:only)?\z/i
        log_file_only = true
      else
        VALID_MODES.each do |mode, re|
          next if re.nil?
          if re.match?(arg)
            set_compilation(mode)
            break
          end
        end
        error "unrecognized switch #{arg.inspect}!" if @mode.nil?
      end
    else
      error "Only one webcam can be monitored per invocation!" unless @webcam.nil?
      @webcam = arg
      img_dir = File::join(CAM_root, 'images', @webcam)
      unless Dir::exist?(img_dir)
        error "Unrecognized webcam: #{@webcam}, no associated directory found under #{CAM_root}"
      end
    end
  end
  error "Please specify mode!" if @mode.nil?
  error "Please specify webcam!" if @webcam.nil?

  prefab_glob = Dir::glob(File::join(img_dir, "#{PREFAB_PFX}-*"))
  if (@mode != :continue)
    error "Previous video compilation incomplete. Please use -continue to resume." if prefab_glob.size > 0
  elsif @mode.eql?(:continue)
    if prefab_glob.size.eql?(0)
      error "No previous video compilation in progress. Please use another mode."
    elsif prefab_glob.size > 1
      error "Multiple previous incomplete video compilations!"
    end
  end

  @logout = File::open(LOG_fn, 'a')

  mp4_date = cur_date
  img_globs = []
  mp4_img_dir = nil
  prev_info = nil

  @pid_fn = PID_fn + "-#{@webcam}.pid"

  ## Make sure we aren't or have already processed this same request
  if File::exist?(@pid_fn)
    prev_info = File::readlines(@pid_fn, chomp: true)
    other_pid = prev_info[0].to_i
    notice "Checking #{other_pid}"
    begin
      if Process.kill(0, other_pid)
        ## There's still another PID running, GTFO
        error "Other Process #{other_pid} found - exiting!"
      end
    rescue Errno::ESRCH
    end
  end

  case @mode
  when :all
    img_globs.push(File::join(img_dir, "*.jpg"))
  when :date, :custom
    img_globs.push(File::join(img_dir, "#{@webcam}-#{cur_date.strftime('%Y%m%d')}-*.jpg"))
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
  when :continue
    if prev_info.nil?
      prefab_dir = File::basename(prefab_glob.first)
      if prefab_dir =~ /\A#{PREFAB_PFX}-(\d{4})(\d{2})(\d{2})-(\w+)\z/
        mp4_date = Time::new($1.to_i, $2.to_i, $3.to_i)
        prev_mode = $4
      else
        error "Unable to parse previous video processing date: #{prefab_dir}"
      end
    else
      prev_mode = prev_info[1][CONTINUE_PFX.size..-1] if prev_info[1].start_with?(CONTINUE_PFX)
      mp4_date = Time.parse(prev_info[2])
    end
    mp4_img_dir = prefab_glob.first
    img_globs.push(File::join(mp4_img_dir, '*.jpg'))
  end

  ## Now that we have the date, compute any custom start and stop time
  if @mode.eql?(:custom)
    begin
      custom_start_time = Time::parse(custom_start, mp4_date)
      custom_stop_time = Time::parse(custom_stop, mp4_date)
      info "Custom video compilation of images between #{custom_start_time.strftime('%H:%M')} and #{custom_stop_time.strftime('%H:%M')}"
    rescue => ex
      error "Invalid custom time format: #{ex.inspect}"
    end
  end

  mp4_date_str = mp4_date.strftime('%Y%m%d')
  mode_str = @mode.to_s

  ## Move the set of images into a "processing" directory
  ## Alsoo calculate a time range of files we are going to be picking up
  if mp4_img_dir.nil?
    mp4_img_dir = make_path(File::join(img_dir, "#{PREFAB_PFX}-#{mp4_date_str}-#{mode_str}"))
  end

  mp4_start_time = mp4_end_time = nil
  mp4_img_paths = []
  img_globs.each do |img_glob|
    img_paths = Dir::glob(img_glob)
    img_paths.each do |img_path|
      img_file = File::basename(img_path)
      if img_file =~ /\A#{@webcam}-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})_(\d{3}).jpg\z/
        begin
          img_time = Time::new($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}.#{$7}".to_f)
        rescue => ex
          warn "Invalid image filename time format: #{img_file} - #{ex.inspect}"
          img_time = nil
        end
      else
        warn "Unrecognized image filename format: #{img_file}"
        img_time = nil
      end
      if @mode.eql?(:continue)
        mp4_img_paths.push(img_path)
      elsif @mode.eql?(:custom) && ((img_time < custom_start_time) || (img_time > custom_stop_time))
        next
      else
        mp4_img_path = File::join(mp4_img_dir, img_file)
        File::rename(img_path, mp4_img_path)
        mp4_img_paths.push(mp4_img_path)
      end
      next if img_time.nil?
      mp4_start_time = img_time if mp4_start_time.nil? || img_time < mp4_start_time
      mp4_end_time = img_time if mp4_end_time.nil? || img_time > mp4_end_time
    end
  end
  mp4_img_glob = File::join(mp4_img_dir, '*.jpg')

  mp4_time_range = "#{mp4_start_time.strftime('%H%M')}_#{mp4_end_time.strftime('%H%M')}"

  mode_str << "-#{prev_mode}" if @mode.eql?(:continue)
  pid_info = "#{Process.pid}\n#{mode_str}\n#{mp4_date.strftime('%Y-%m-%d')}\n#{mp4_time_range}\n"
  File::write(@pid_fn, pid_info)

  mp4_dir = make_path(File::join(CAM_root, 'video', mp4_date.strftime('%Y'), mp4_date.strftime('%m')))
  mp4_path = File::join(mp4_dir, "#{@webcam}-#{mp4_date_str}-#{mp4_time_range}.mp4")

  info_msg = @mode.eql?(:continue) ? "Resuming #{prev_mode}" : "Processing #{@mode.to_s}"
  info "#{info_msg} video compilation for #{mp4_date_str}-#{mp4_time_range} (#{mp4_img_paths.size} images)"
  begin
    cmd = "ffmpeg -y "
    cmd << "-f image2 -framerate 5 -pattern_type glob -i '#{mp4_img_glob}' "
    ##cmd << "-c:v libx264 "    ## Not currently available on OpenWRT Raspberry Pi
    cmd << "-movflags +faststart #{mp4_path}"
    cmd_resp = []
    cmd_status = nil
    Open3::popen2e(cmd) do |stdin, stdout, wait_thr|
      stdin.close_write
      newline_needed = false
      while cmdout = get_line(stdout)
        ## Note: The following only goes to $stdout
        if cmdout.start_with?('frame=')
          unless log_file_only
            $stderr.print "#{cmdout}\r"
            newline_needed = true
          end
        else
          unless log_file_only
            if newline_needed
              $stderr.print "\n"
              newline_needed = false
            end
            $stderr.puts cmdout 
          end
          cmd_resp << cmdout
        end
      end
      cmd_status = wait_thr.value
    end
    if cmd_status != 0
      msg = "command failed (#{cmd_status})"
      error(msg, logout: false) unless log_file_only
      error(msg << "\nCMD:\t#{cmd}\nOUT:\t#{cmd_resp}\n", stdout: false)
    else
      info(cmd_resp.join("\n"), stdout: false)
    end
  rescue Errno => ex
    msg = "#{ex.inspect}"
    error(msg, logout: false) unless log_file_only
    error(msg << "\nCMD:\t#{cmd}", stdout: false)
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

  info "Processed #{mp4_img_paths.size} images into #{mode_str} video!"

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

end
