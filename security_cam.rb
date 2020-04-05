#!/usr/bin/env ruby

require 'net/http'
require 'fileutils'
require 'open3'
require 'byebug'

## Security camera credentials are kept in the following un-committed location
## following this format:
## CAM_creds = {
##    'user' => '<username>',
##    'pwd' => '<password>'
##  }
require_relative File::expand_path('~/.cam_creds.rb')

WEBCAMS = {
  'shop-alley-cam' => 'http://shop-alley.cam.dltk-hansen.org'
}

CAM_root = '/data/security'

CAM_period = 0.5              ## How often to capture frames for analysis
CAM_max_delta = 120.0         ## Max seconds of no change before capturing frame anyway

CAM_MAE_avg_size = 600        ## Number of samples to average MAE for comparison
CAM_MAE_threshold_pct = 0.08  ## 8% change compared to MAE average triggers frame save

CAM_IMG_font = '/usr/share/freeswitch/fonts/FreeMono.ttf'

SNAPSHOT_url = '/snapshot.cgi'
STREAM_url = '/videostream.cgi'

DECODER_CTL_url = 'decoder_control.cgi'
DECODER_IR_ON =   { 'command' => '95' }
DECODER_IR_OFF =  { 'command' => '94' }

LOG_File = '/data/security/security_cam.log'
PID_File = '/var/run/security_cam.pid'


@logout = $stdout
@logerr = $stderr

def time_str
  Time.now.strftime('[%Y-%m-%d_%H:%M:%S.%3N_%Z]')
end

def error(msg, opts = {action: :exit})
  @logerr.puts("#{time_str} \e[1;33;41mERROR:\e[0m #{msg}")
  case opts[:action]
  when :exit, nil then exit 255
  when :continue then return;
  else raise "Invalid error action: #{opts[:action].inspect}, must be :exit or :continue"
  end
end

def warn(msg)
  @logerr.puts("#{time_str} \e[1;33;43mWARNING:\e[0m #{msg}")
end

def status(msg = '', opts = {})
  @logerr.puts("#{time_str} #{opts[:tag] ? "\e[30;47m#{opts[:tag]}\e[0m " : ''}#{msg}")
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
  gm_cmd = "gm convert -font #{CAM_IMG_font} -pointsize 16 -fill white -draw \"text 10,10 '#{time.strftime('%Y/%m/%d %H:%M:%S.%3N')}'\" #{file} #{file}"
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

trap('SIGHUP') { reopen_log }
trap('SIGQUIT') { @quit = true }
trap('SIGINT') { @quit = true }

begin
  @webcam = nil
  @daemon = false
  @quit = false

  while ARGV.size > 0
    arg = ARGV.shift
    case arg
    when /\A-daemon\z/i
      @daemon = true
    else
      error "Only one webcam can be monitored per invocation!" unless @webcam.nil?
      @webcam = arg
      unless WEBCAMS.keys.include?(@webcam)
        error "Unrecognized webcam: #{@webcam}, please choose from #{WEBCAMS.keys.inspect}"
      end
    end
  end
  error "Please specify webcam from #{WEBCAMS.keys.inspect}" if @webcam.nil?

  if @daemon
    ## If another is running, kill it first
    if File::exist?(PID_File)
      other_pid = File::read(PID_File).to_i
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
    File::write(PID_File, "#{Process.pid}\n")
  end


  @logout.sync = true
  @logerr.sync = true

  @snapshot_uri = URI(WEBCAMS[@webcam] + SNAPSHOT_url)
  @snapshot_uri.query = URI.encode_www_form(CAM_creds)
  @http = nil

  ## Get the next image
  @snapshot_req = Net::HTTP::Get.new(@snapshot_uri)
  @snapshot_req['User-Agent'] = 'security_cam.rb'
  @snapshot_req['Connection'] = 'keep-alive'

  mae_avg = nil
  cur_time = Time.now
  last_time = cur_time - CAM_period - 0.1
  prev_img_path = img_path = nil
  prev_img_time = nil
  err_count = 0
  until @quit do
    cur_day = cur_time.day
    date_dir = File::join(CAM_root, @webcam, cur_time.strftime('%Y'), cur_time.strftime('%m'), cur_time.strftime('%d'))
    unless Dir::exist?(date_dir)
      FileUtils::mkdir_p(date_dir) 
      notice "Created directory #{date_dir}"
    end
    pfx_sz = File::join(date_dir, "#{@webcam}-YYYYmmdd-HH").size
    until @quit do
      # Delay until the next CAM_period
      break unless cur_time.day.eql?(cur_day)
      wait_secs = (last_time + CAM_period) - cur_time
      last_time = cur_time
      sleep(wait_secs) if wait_secs > 0.0
      cur_time = Time.now

      @http = Net::HTTP.start(@snapshot_uri.hostname, @snapshot_uri.port) if @http.nil?
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
        img_path = File::join(date_dir, "#{@webcam}-#{cur_time.strftime('%Y%m%d-%H%M%S_%3N')}.jpg")
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
            diff = (mae > mae_avg) ? (mae - mae_avg) : (mae_avg - mae)
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
    File::delete(PID_File) if File::exist?(PID_File)
  end
end

#ffmpeg -f image2 -framerate 5 -pattern_type glob -i '20170116*.jpg' -pix_fmt yuv420p shop-alley-cam_20170116.mp4
#compare -metric MAE ${args} ${dir}/${cur} ${dir}/${last}
