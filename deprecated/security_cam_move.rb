#!/usr/bin/env ruby

CAM_Root = '/shop-alley-cam/';
CAM_Prefix = '00626E542693(shop-alley-cam)'

LOG_File = '/var/log/security_cam_move.log'
PID_File = '/var/run/security_cam_move.pid'

@logout = $stdout
@logerr = $stderr

def time_str
  Time.now.strftime('[%Y-%m-%d_%H:%M:%S_%Z]')
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
  notice "reopening log file"
  @logerr.close unless @logerr.eql?(@logout)
  @logout.close
  @logout = @logerr = File::open(LOG_File, 'a')
  notice "log file reopened"
end

trap('SIGHUP') { reopen_log }
trap('SIGQUIT') { @quit = true }

begin
  daemon=false
  today=Time.now
  cur_dir = File::join(CAM_Root, 'current')
  @quit = false

  case ARGV[0]
  when /\A-rotate\z/i
    ## This shuffles the old current to a previous dir and remakes a new current dir
    prev_dir = File::join(CAM_Root, "previous-#{today.strftime('%Y%m%d')}")
    File::rename(cur_dir, prev_dir)
    Dir::mkdir(cur_dir)
  when /\A-daemon\z/i
    @logout = @logerr = File::open(LOG_File, 'a')
    prev_dir = cur_dir
    Process.daemon
    File::write(PID_File, "#{Process.pid}\n")
    daemon = true
  else
    prev_dir = cur_dir
  end

  @logout.sync = true
  @logerr.sync = true

  loop do
    dir = Dir::new(prev_dir)
    found_images = false
    dir.each do |fname|
      next unless fname.start_with?(CAM_Prefix)
      match = /\A_([01])_(\d{8})(\d{6})_(\d*)\.jpg\z/.match(fname[CAM_Prefix.size..-1])
      if match.nil?
        warn("Unsupported filename: #{fname} - SKIPPING")
        next
      end
      month_dir = File::join(CAM_Root, match[2][0..5])
      Dir::mkdir(month_dir) unless File::directory?(month_dir)
      date_dir = File::join(month_dir, match[2])
      Dir::mkdir(date_dir) unless File::directory?(date_dir)
      new_fname = File::join(date_dir, "#{match[2]}_#{match[3]}_#{match[4]}_#{match[1]}.jpg")
      old_fname = File::join(prev_dir, fname)
      begin
        File::rename(old_fname, new_fname)
      rescue => ex
        error("EXCEPTION - #{ex}", action: :continue)
        next
      end
      @logout.puts "#{time_str} MOVED #{old_fname} -> #{new_fname}"
      found_images = true
      break if @quit
    end
    dir.close
    break if @quit
    if daemon
      info "#{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')} - Sleeping 180..."
      sleep 180
    else
      ## Continue looping until we've found/moved some images
      break unless found_images
    end
  end
  Dir::rmdir(prev_dir) unless prev_dir.eql?(cur_dir) || @quit
  notice "Exiting"

ensure
  File::delete(PID_File)
end

#ffmpeg -f image2 -framerate 5 -pattern_type glob -i '20170116*.jpg' -pix_fmt yuv420p shop-alley-cam_20170116.mp4
#compare -metric MAE ${args} ${dir}/${cur} ${dir}/${last}
