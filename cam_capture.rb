#!/usr/bin/env ruby

require 'net/http'
require 'fileutils'
require 'open3'
require 'sun'
##require 'byebug'

## Security camera credentials are kept in the following un-committed location
## following this format:
##
## CAM_creds = {
##    'user' => '<username>',
##    'pwd' => '<password>'
##  }
## CAM_latitude = XX.XX
## CAM_longitude = XXX.xx
## CAM_root = '<root_path>'
## CAM_font = '<font_path>'.freeze
##
## CAM_list = {
##    '<camera-name>' => '<camera-url>'
##   }
##
require_relative File::expand_path('~/.cam_creds.rb')


CAM_period = 0.5              ## How often to capture frames for analysis
CAM_max_delta = 120.0         ## Max seconds of no change before capturing frame anyway

CAM_cmp_metric = 'rmse'
CAM_cmp_defs = {
    'rmse' => {
          avg_size: 600,        ## Number of samples to average RMSE for baseline
          avg_cap: 0.025,       ## Cap rmse avg at 2.5%
          threshold_pct: 0.15,  ## 12% change over average RMSE baseline triggers frame save
      },
    'mae' =>  {
          avg_size: 600,        ## Number of samples to average MAE for baseline
          avg_cap: 0.017,       ## Cap mae avg at 1.7%
          threshold_pct: 0.08,  ## 8% change over average MAE baseline triggers frame save
      },
  }
CAM_cmp_ctrl = CAM_cmp_defs[CAM_cmp_metric]

SNAPSHOT_url = '/snapshot.cgi'.freeze
STREAM_url = '/videostream.cgi'.freeze
CAMERA_CTL_url = '/camera_control.cgi'.freeze
CONTRAST_SETTING = { 'param' => 2, value: nil }
DECODER_CTL_url = '/decoder_control.cgi'.freeze
DECODER_IR_ON =   { 'command' => '95' }
DECODER_IR_OFF =  { 'command' => '94' }
CAM_IR_MODE = {
    on:   DECODER_IR_ON,
    off:  DECODER_IR_OFF
  }

COMMON_HTTP_HDRS = {
    'User-Agent' => 'security_cam.rb',
    'Connection' => 'keep-alive',
  }

@http_uri = nil
@http_conn = nil
@http_req_count = 0
@http_err_count = 0
@snapshot_uri = nil
@snapshot_req = nil
@decoder_ctl_uri = nil
@decoder_ctl_req = {}
@camera_ctl_uri = nil   ## Camera ctl requests need to be made every time

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze

LOG_file_path = File::join(CAM_root, 'logs').freeze
PID_file_prefix = '/var/run/cam_capture'.freeze


$stdout.sync = true
$stderr.sync = true

@logout = $stdout
@logerr = $stderr

def log_prefix
  "#{Time.now.strftime(LOG_TIME_fmt)}CC(#{@webcam})"
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

def reopen_log
  notice "SIGHUP received"
  return if @logout.eql?($stdout)
  notice "closing and (re)opening log file" ## This ends up in the old log file
  @logerr.close unless @logerr.eql?(@logout)
  @logout.close
  @logout = @logerr = File::open(@log_fn, 'a')
  notice "log file reopened"  ## This should end up in the new log file
end

def make_path(path)
  unless Dir::exist?(path)
    FileUtils::mkdir_p(path) 
    notice "Created directory #{path}"
  end
  path
end

def gm_timestamp(img_file, time, new_path)
  ret = nil
  new_img_file = File::join(new_path, File::basename(img_file))
  gm_cmd = "gm convert -font #{CAM_font} -pointsize 16 -fill white -draw \"text 10,15 '#{time.strftime('%Y/%m/%d %H:%M:%S.%3N')}'\" #{img_file} #{new_img_file}"
  stdout, stderr, status = Open3.capture3(gm_cmd)
  err = stderr.strip
  if err.size > 0 || status != 0
    error("failed #{status}: #{err}", action: :continue)
    File::rename(img_file, new_img_file) unless File::size?(new_img_file)
  end
  File::delete(img_file) if File::exist?(img_file)
  ret
rescue Errno::ENOENT => e
  error("#{gm_cmd}\n\t#{e.message}", action: :continue)
  nil
end

def gm_compare(file1, file2)
  ret = nil
  gm_cmd = "gm compare -metric #{CAM_cmp_metric} #{file1} #{file2}"
  stdout, stderr, status = Open3.capture3(gm_cmd)
  err = stderr.strip
  if err.size > 0 || status != 0
    error("failed #{status}: #{err}", action: :continue)
  else
    stdout.strip!
    if stdout =~ /Total:\s+([0-9.]+)\s+/
      begin
        ret = Float($1)
      rescue ArgumentError
        error("invalid Total diff from gm compare: #{$stdout}", action: :continue)
      end
    end
  end
  ret
rescue Errno::ENOENT => e
  error("#{gm_cmd}\n\t#{e.message}", action: :continue)
  nil
end

def make_request(req)
  if @http_conn.nil?
    @http_conn = Net::HTTP.start(@http_uri.hostname, @http_uri.port) 
    @http_req_count = 0
    @http_err_count = 0
  end
  begin
    @http_req_count += 1
    resp = @http_conn.request(req)
    if resp && resp.is_a?(Net::HTTPSuccess)
      data = resp.body
      @http_err_count = 0
    else
      err_msg = "HTTP request(#{req.to_hash}) => \n#{resp.inspect}"
      @http_err_count += 1
      if @http_err_count > 5
        @http_err_count = 0
        error err_msg, action: :continue
        sleep 60
      else
        warn err_msg
      end
      data = nil
    end
  rescue => ex
    error "HTTP request\n#{ex.inspect}\nTOTAL REQUESTS: #{@http_req_count}", action: :continue
    @http_conn = nil
    data = nil
  end
  data
end

def take_snapshot
  ## Get the next image
  @snapshot_uri = URI(CAM_list[@webcam] + SNAPSHOT_url) if @snapshot_uri.nil?
  if @snapshot_req.nil?
    @snapshot_uri.query = URI.encode_www_form(CAM_creds)
    @snapshot_req = Net::HTTP::Get.new(@snapshot_uri, COMMON_HTTP_HDRS)
  end
  make_request(@snapshot_req)
end

def ir_control(mode)
  raise "Bad mode #{mode.inspect}!" unless CAM_IR_MODE.key?(mode)
  @decoder_ctl_uri = URI(CAM_list[@webcam] + DECODER_CTL_url) if @decoder_ctl_uri.nil?
  unless @decoder_ctl_req.key?(mode)
    @decoder_ctl_uri.query = URI.encode_www_form(CAM_IR_MODE[mode].merge(CAM_creds))
    @decoder_ctl_req[mode] = Net::HTTP::Get.new(@decoder_ctl_uri, COMMON_HTTP_HDRS)
  end
  if make_request(@decoder_ctl_req[mode])
    warn "IR mode #{mode.to_s}"
  else
    error "IR control #{mode.to_s} failed", action: :continue
    mode = nil
  end
  mode
end

def adjust_contrast(level)
  raise "Bad contrast level #{level} (must be >= 0 and <= 6)!" unless (level >= 0) && (level <= 6)
  CONTRAST_SETTING['value'] = level
  @camera_ctl_uri = URI(CAM_list[@webcam] + CAMERA_CTL_url) if @camera_ctl_uri.nil?
  @camera_ctl_uri.query = URI.encode_www_form(CONTRAST_SETTING.merge(CAM_creds))
  req = Net::HTTP::Get.new(@camera_ctl_uri, COMMON_HTTP_HDRS)
  if make_request(req)
    warn "Contrast level set to #{level}"
  else
    error "Camera control for contrast #{level} failed", action: :continue
  end
end

trap('SIGHUP') { reopen_log }
trap('SIGQUIT') { @quit = true }
trap('SIGINT') { @quit = true }

begin
  @webcam = nil
  @daemon = false
  @pid_fn = nil
  @log_fn = nil
  @quit = false

  while ARGV.size > 0
    arg = ARGV.shift
    case arg
    when /\A-daemon\z/i
      @daemon = true
    else
      error "Only one webcam can be monitored per invocation!" unless @webcam.nil?
      @webcam = arg
      unless CAM_list.keys.include?(@webcam)
        error "Unrecognized webcam: #{@webcam}, please choose from #{CAM_list.keys.inspect}"
      end
    end
  end
  error "Please specify webcam from #{CAM_list.keys.inspect}" if @webcam.nil?

  if @daemon
    ## If another is running, kill it first
    @pid_fn = PID_file_prefix + "-#{@webcam}.pid"
    if File::exist?(@pid_fn)
      other_pid = File::read(@pid_fn).to_i
      begin
        ## make sure other PID is gone before continuing
        wait_cnt = 0
        sts = Process.kill('SIGINT', other_pid)
        while sts > 0
          notice "Waiting for #{other_pid} to exit" if (wait_cnt % 10) == 0
          sleep 1
          wait_cnt += 1
          if (wait_cnt >= 150)        ## After 150 seconds -> give up
            error "Failed to stop #{other_pid}!!!"
          elsif (wait_cnt >= 120)     ## After 120 seconds -> time to HARD KILL
            warn "Killing #{other_pid} with SIGKILL!!!"
            sig = 'SIGKILL'
          elsif (wait_cnt % 30) == 0  ## After each 30 seconds, re-send SIGINT
            warn "Killing #{other_pid} with SIGINT again!"
            sig = 'SIGINT'
          else
            sig = 0
          end
          sts = Process.kill(sig, other_pid)
        end
      rescue Errno::ESRCH
        notice "Process #{other_pid} not active -> continuing to daemonize"
      end
    end
    @log_fn = File::join(LOG_file_path, "cam_capture-#{@webcam}.log")
    @logout = @logerr = File::open(@log_fn, 'a')
    Process.daemon
    File::write(@pid_fn, "#{Process.pid}\n")
  end

  ## Note: This (might) cause unnecessarily heavy write activity on the same disk block on a flash
  ## Comment out if so.
  @logout.sync = true
  @logerr.sync = true

  @http_uri = URI(CAM_list[@webcam])

  metric_baseline = nil
  cur_time = Time.now
  last_time = cur_time - CAM_period - 0.1
  prev_img_path = img_path = nil
  prev_img_time = nil
  webcam_ir_mode = nil
  save_dir = make_path(File::join(CAM_root, 'images', @webcam))
  temp_dir = make_path(File::join('', 'tmp', 'security-cam', 'images', @webcam))
  pfx_sz = File::join(temp_dir, "#{@webcam}-YYYYmmdd-HH").size
  contrast_level = nil
  contrast_time = nil
  until @quit do
    cur_day = cur_time.day

    ## Determine sunrise and sunset for today
    sunrise = Sun::sunrise(cur_time, CAM_latitude, CAM_longitude)
    sunset = Sun::sunset(cur_time, CAM_latitude, CAM_longitude)

    until @quit do
      ## Delay until the next CAM_period
      break unless cur_time.day.eql?(cur_day)
      wait_secs = (last_time + CAM_period) - Time.now
      sleep(wait_secs) if wait_secs > 0.0
      last_time = cur_time
      cur_time = Time.now

      ## Check if we need to turn on/off IR
      if (cur_time > sunrise) && (cur_time < sunset)
        webcam_ir_mode = ir_control(:off) unless webcam_ir_mode.eql?(:off)
        ## Perhaps during the day, increase contrast?
        ## Tends to really darken some areas though and trigger more movement.
        #contrast_level = 4
        #contrast_time = cur_time
      else
        unless webcam_ir_mode.eql?(:on)
          webcam_ir_mode = ir_control(:on)
          #contrast_time = Time::parse("22:30:00", cur_time) ## Adjust/fix contrast @ 10:30PM
          contrast_time = cur_time + 1800 ## Adjust/fix contrast in 30 minutes
          contrast_level = 3
        end
      end
      next if webcam_ir_mode.nil?

      if contrast_time && (cur_time >= contrast_time)
        ## At night, we'll first take contrast to 0 to "reset" the camera
        if (cur_time > sunset)
          [0...contrast_level].each do |level|
            adjust_contrast(level)
            sleep(5)      ## Wait for camera to stabilize
          end
        end
        adjust_contrast(contrast_level)
        contrast_time = nil
        sleep(5) ## don't take a snapshot straight away, wait for camera adjust to new contrast level
      end

      snapshot = take_snapshot
      next if snapshot.nil?

      img_path = File::join(temp_dir, "#{@webcam}-#{cur_time.strftime('%Y%m%d-%H%M%S_%3N')}.jpg")
      File::write(img_path, snapshot)

      ## Determine if this is a different enough image to keep
      if prev_img_path.nil?
        prev_img_path = img_path
        prev_img_time = cur_time
      else
        metric_val = gm_compare(prev_img_path, img_path)
        if metric_val.nil?
          action = :ERROR
        else
          metric_capped = (metric_val < CAM_cmp_ctrl[:avg_cap]) ? metric_val : CAM_cmp_ctrl[:avg_cap]
          if metric_baseline.nil?
            metric_ary = [metric_capped] * CAM_cmp_ctrl[:avg_size]
            metric_baseline = metric_capped
          else
            metric_baseline += (metric_capped - metric_ary.shift)/metric_ary.size
            metric_ary.push(metric_capped)
          end
          diff = metric_val - metric_baseline
          action = 
            if (diff > (metric_baseline * CAM_cmp_ctrl[:threshold_pct]))
              :SAVED
            elsif ((cur_time - prev_img_time) > CAM_max_delta)
              :SYNC
            else
              :drop
            end
          info "#{webcam_ir_mode.eql?(:on) ? 'IR ' : ''}compare [#{prev_img_path[pfx_sz..-5]} ≟ #{img_path[pfx_sz..-5]}] #{sprintf('≏:%.4f, ⌀:%.4f, Δ:%.4f', metric_val, metric_baseline, diff)} -> #{action.to_s}"
        end
        case action
        when :SAVED, :SYNC
          gm_timestamp(prev_img_path, prev_img_time, save_dir)
          prev_img_path = img_path
          prev_img_time = cur_time
        when :drop, :ERROR
          File::delete(img_path)
        end
      end
    end
  end

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

ensure
  ## Make sure last frame was timestamped upon exit
  gm_timestamp(prev_img_path, prev_img_time, save_dir) unless prev_img_path.nil?
  notice "Exiting"
  if @daemon
    @logout.close
    File::delete(@pid_fn) if @pid_fn && File::exist?(@pid_fn)
  end
end
