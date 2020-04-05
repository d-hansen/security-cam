#!/usr/bin/perl
use Expect;
$| = 1; # Force flush after every print
$0 =~ /(.*\/)*/;
$ProgName = $';

@time = localtime(time);
$year = $time[5] + 1900;
$mon = $time[4] + 1;
$day = $time[3];
$today = sprintf("%4d%02d%02d", $year, $mon, $day);
$total = 0;
$count = 1;

$CAMshare = '//R6400/shop-alley-cam';
$CAMfn = '00626E542693(shop-alley-cam)';
$CAMfnre = qr/^\s+00626E542693\(shop-alley-cam\)_([01])_(\d{8})(\d{6})_(\d*)\.jpg\s.*\r?$/m;
$SMBprmpt = qr/^smb: \\>/m;

##$Expect::Debug = 3;
$smbclnt = Expect->spawn("smbclient -N $CAMshare")
            || die "Unable to spawn smbclient to $CAMshare";
$smbclnt->log_stdout(0);
$smbclnt->expect(10, '-re', $SMBprmpt) || die "No smbclient prompt found";

$smbclnt->send("timeout 60\r");
$smbclnt->expect(10, '-re', $SMBprmpt) || die "No smbclient prompt found";

$smbclnt->send("rename current previous-$today\r");
$smbclnt->expect(30, '-re', $SMBprmpt) || die "No smbclient prompt found";

$smbclnt->send("mkdir current\r");
$smbclnt->expect(30, '-re', $SMBprmpt) || die "No smbclient prompt found";

sub CAMFileProc {
    my $self = shift;
    @info = $self->matchlist;
    printf "GOT: $info[3] @ $info[2] on $info[1] [$info[0]] - $CAMfn\n";
    if (!exists $days{$info[1]}) { $days{$info[1]} = (); }
    my %files = $days{$info[1]};
    $files{"$info[1]_$info[2]_$info[3]_$info[0].jpg"} = "${CAMfn}_$info[0]_$info[1]$info[2]_$info[3].jpg";
    exp_continue;
}

sub CAMFileMove {
    my $dir = shift(@_);
    $smbclnt->send("mkdir $dir\r");
    $smbclnt->expect(60, '-re', $SMBprmpt) || die "No smbclient prompt found";
    my %files = $days{$dir};
    foreach $key (sort keys %files) {
        printf "transferring previous-$today/$files{$key} -> $dir/$key\n";
        $smbclnt->send("rename previous-$today/$files{$key} $dir/$key\r");
        $smbclnt->expect(60, '-re', $SMBprmpt) || die "No smbclient prompt found";
        $total += 1;
        $count += 1;
    }
}

while ($count != 0) {
    %days = ();
    $count = 0;

    $smbclnt->send("dir previous-$today/${CAMfn}_*\r");
    $smbclnt->expect(60,
        '-re', $CAMfnre, \&CAMFileProc,
        '-re', $SMBprmpt
    );

    #$smbclnt->log_stdout(1);
    foreach $key (sort keys %days) {
        my %files = $days{$key};
        printf "$key: %d files\n", scalar keys %files;
        CAMFileMove $key;
    }
}
printf "\nTOTAL Moved: %d\n\n", $total;

$smbclnt->send("rmdir previous-$today\r");
$smbclnt->expect(30, '-re', $SMBprmpt) || die "No smbclient prompt found";

$smbclnt->send("quit\r");
$smbclnt->expect(5, eof);

exit 0
