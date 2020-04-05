#!/usr/bin/env ruby

require 'net/http'
require 'fileutils'
require 'open3'
require 'sun'
require 'byebug'

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

CAM_MAE_avg_size = 600        ## Number of samples to average MAE for comparison
CAM_MAE_threshold_pct = 0.08  ## 8% change compared to MAE average triggers frame save

SNAPSHOT_url = '/snapshot.cgi'.freeze
STREAM_url = '/videostream.cgi'.freeze

DECODER_CTL_url = '/decoder_control.cgi'.freeze
DECODER_IR_ON =   { 'command' => '95' }
DECODER_IR_OFF =  { 'command' => '94' }
CAM_IR_MODE = {
    on:   DECODER_IR_ON,
    off:  DECODER_IR_OFF
  }

LOG_TIME_fmt = '[%Y-%m-%d_%H:%M:%S.%3N_%Z]'.freeze
LOG_File = File::join(CAM_root, 'cam_capture.log').freeze
PID_File = '/var/run/cam_capture'.freeze


$stdout.sync = true
$stderr.sync = true

@logout = $stdout
@logerr = $stderr

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
  notice "(re)opening log file"
  @logerr.close unless @logerr.eql?(@logout)
  @logout.close
  @logout = @logerr = File::open(LOG_File, 'a')
  notice "log file reopened"
end

def gm_timestamp(file, time)
  ret = nil
  gm_cmd = "gm convert -font #{CAM_font} -pointsize 16 -fill white -draw \"text 10,10 '#{time.strftime('%Y/%m/%d %H:%M:%S.%3N')}'\" #{file} #{file}"
  stdout, stderr, status = Open3.capture3(gm_cmd)
  err = stderr.strip
  if err.size > 0 || status != 0
    error("failed #{status}: #{err}", action: :continue)
  end
  ret
rescue Errno::ENOENT => e
  error("#{gm_cmd}\n\t#{e.message}", action: :continue)
  nil
end

def gm_compare(file1, file2)
  ret = nil
  gm_cmd = "gm compare -metric MAE #{file1} #{file2}"
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

def decoder_ctl(mode)
  raise "Bad mode #{mode.inspect}!" unless @decoder_ctl_req.key?(mode)
  begin
    resp = @http.request(@decoder_ctl_req[mode])
    if resp.is_a?(Net::HTTPSuccess)
      warn "IR mode #{mode.to_s}"
    else
      error "IR control #{mode.to_s} => #{resp.inspect}", action: :continue
      mode = nil
    end
  rescue => ex
    error "HTTP request - #{ex.inspect}", action: :continue
    @http = nil
    mode = nil
  end
  mode
end

trap('SIGHUP') { reopen_log }
trap('SIGQUIT') { @quit = true }
trap('SIGINT') { @quit = true }

begin
  @webcam = nil
  @daemon = false
  @pid_file = nil
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
    @pid_file = PID_File + "-#{@webcam}.pid"
    if File::exist?(@pid_file)
      other_pid = File::read(@pid_file).to_i
      notice "Killing #{other_pid}"
      begin
        ## make sure other PID is gone before continuing
        Process.kill('SIGINT', other_pid)
        while Process.kill(0, other_pid)
          notice "Waiting on #{other_pid}"
          sleep 1 
        end
      rescue Errno::ESRCH
        notice "Process #{other_pid} not found - continuing to daemonize"
      end
    end
    @logout = @logerr = File::open(LOG_File, 'a')
    Process.daemon
    File::write(@pid_file, "#{Process.pid}\n")
  end


  ## This causes unnecessarily heavy rewrite of the same block on the flash
  #@logout.sync = true
  #@logerr.sync = true

  @http = nil

  ## Get the next image
  @snapshot_uri = URI(CAM_list[@webcam] + SNAPSHOT_url)
  @snapshot_uri.query = URI.encode_www_form(CAM_creds)
  @snapshot_req = Net::HTTP::Get.new(@snapshot_uri)
  @snapshot_req['User-Agent'] = 'security_cam.rb'
  @snapshot_req['Connection'] = 'keep-alive'

  @decoder_ctl_uri = URI(CAM_list[@webcam] + DECODER_CTL_url)
  @decoder_ctl_req = {}
  CAM_IR_MODE.keys.each do |mode|
    @decoder_ctl_uri.query = URI.encode_www_form(CAM_IR_MODE[mode].merge(CAM_creds))
    @decoder_ctl_req[mode] = Net::HTTP::Get.new(@decoder_ctl_uri)
    @decoder_ctl_req[mode]['User-Agent'] = 'security_cam.rb'
    @decoder_ctl_req[mode]['Connection'] = 'keep-alive'
  end

  mae_avg = nil
  cur_time = Time.now
  last_time = cur_time - CAM_period - 0.1
  prev_img_path = img_path = nil
  prev_img_time = nil
  err_count = 0
  webcam_ir_mode = nil
  cur_dir = File::join(CAM_root, @webcam, 'current')
  unless Dir::exist?(cur_dir)
    FileUtils::mkdir_p(cur_dir) 
    notice "Created directory #{cur_dir}"
  end
  pfx_sz = File::join(cur_dir, "#{@webcam}-YYYYmmdd-HH").size
  until @quit do
    cur_day = cur_time.day

    ## Determine sunrise and sunset for today
    sunrise = Sun::sunrise(cur_time, CAM_latitude, CAM_longitude)
    sunset = Sun::sunset(cur_time, CAM_latitude, CAM_longitude)

    until @quit do
      ## Delay until the next CAM_period
      break unless cur_time.day.eql?(cur_day)
      wait_secs = (last_time + CAM_period) - cur_time
      last_time = cur_time
      sleep(wait_secs) if wait_secs > 0.0
      cur_time = Time.now

      @http = Net::HTTP.start(@snapshot_uri.hostname, @snapshot_uri.port) if @http.nil?

      ## Check if we need to turn on/off IR
      webcam_decoder_ctl_params = nil
      if (cur_time > sunrise) && (cur_time < sunset) && (webcam_ir_mode != :off)
        webcam_ir_mode = decoder_ctl(:off)
      elsif (webcam_ir_mode != :off)
        webcam_ir_mode = decoder_ctl(:on)
      end
      next if webcam_ir_mode.nil?

      begin
        resp = @http.request(@snapshot_req)
      rescue => ex
        error "HTTP request - #{ex.inspect}", action: :continue
        @http = nil
        resp = nil
      end

      if resp.nil?
        next
      elsif resp.is_a?(Net::HTTPSuccess)
        err_count = 0
        img_path = File::join(cur_dir, "#{@webcam}-#{cur_time.strftime('%Y%m%d-%H%M%S_%3N')}.jpg")
        File::write(img_path, resp.body)

        ## Determine if this is a different enough image to keep
        if prev_img_path.nil?
          prev_img_path = img_path
          prev_img_time = cur_time
        else
          mae = gm_compare(prev_img_path, img_path)
          if mae.nil?
            action = 'ERROR'
          else
            if mae_avg.nil?
              mae_ary = [mae] * CAM_MAE_avg_size
              mae_avg = mae
            else
              mae_avg += (mae - mae_ary.shift)/mae_ary.size
              mae_ary.push(mae)
            end
            diff = mae - mae_avg
            action = 
              if (diff > (mae_avg * CAM_MAE_threshold_pct))
                'SAVED'
              elsif ((cur_time - prev_img_time) > CAM_max_delta)
                'SYNC'
              else
                'drop'
              end
            info "compare [#{prev_img_path[pfx_sz..-5]} ≏ #{img_path[pfx_sz..-5]}] #{sprintf('mae:%.4f, ⌀:%.4f, Δ:%.4f', mae, mae_avg, diff)} -> #{action}"
          end
          case action
          when 'SAVED', 'SYNC'
            gm_timestamp(prev_img_path, prev_img_time)
            prev_img_path = img_path
            prev_img_time = cur_time
          when 'drop', 'ERROR'
            File::delete(img_path)
          end
        end
      else
        err_count += 1
        if err_count > 5
          error resp.inspect, action: :continue
          sleep 60
        else
          warn resp.inspect
        end
      end
    end
  end

rescue => ex
  error("#{ex.inspect}\n\t#{ex.backtrace.join("\n\t")}", action: :continue)

ensure
  ## Make sure last frame was timestamped upon exit
  gm_timestamp(prev_img_path, prev_img_time) unless prev_img_path.nil?
  notice "Exiting"
  if @daemon
    @logout.close
    File::delete(@pid_file) if @pid_file && File::exist?(@pid_file)
  end
end
