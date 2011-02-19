#!/usr/bin/perl

use warnings;
use strict;

use LWP::UserAgent;
use DBI;

my $DELAY = 5;
my $PATH    = "/home/cpbills/projects/find-room";
my $base = 'http://sfbay.craigslist.org/sby/roo/';
my $email = 'email@add.re.ss';
my $date = `date +%F`;
my $OLDROOMS = "$PATH/cl-crawl.rooms";
my $SENDMAIL = "/usr/sbin/sendmail -t";
chomp $date;
my @possible = ();  # array for desireable jobs

my $THRESHOLD = 0;
my $debug = 0;


# hash of jobs we've seen
my %beendone = ();

readdone() if (-e $OLDROOMS); 

sub readdone {
    open FILE,$OLDROOMS;
    my @done = <FILE>;
    close FILE;

    chomp(@done);

    foreach my $oldroom (@done) {
        my ($url,$seen) = split(/::/,$oldroom);
        # increase the seen count; this allows us
        # to eventually write code/etc to remove
        # old jobs that are no longer in the listings
        $beendone{$url} = ++$seen;
    }
}

# hash of keywords
my %words = (
    'mountain\ view'    => 10,
    'sunnyvale'         => 9,
    'los\ altos'        => 8,
    'caltrain'          => 6,
    'train'             => 5,
    'palo\ alto'        => 4,
    'los gatos'         => 3,
    'san\ jose'         => 3
);

my $errors = '';

main();

sub main {
    my $rooms  = get_page($base);
       $rooms .= get_page("${base}index100.html");
       $rooms .= get_page("${base}index200.html");
       $rooms .= get_page("${base}index300.html");
       $rooms .= get_page("${base}index400.html");
       $rooms .= get_page("${base}index500.html");
    if (!defined $rooms) {
        my $error = "failed to get rooms: $! ($base)\n";
        print $error;
        $errors .= $error;
    } else {
        parse_rooms($rooms,$base);
    }
    results();
}

sub results {
    print "sending an email!\n";
    my @sorted = sort {
        # originally set to sort by date, then score, that ended up
        # more frustrating than not.
        my ($da,$sa) = $a =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        my ($db,$sb) = $b =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        #return -1 if ($da gt $db);
        #return  1 if ($db gt $da);
        #if ($da eq $db) {
            return -1 if ($sa > $sb);
            return  1 if ($sb > $sa);
        #}
        return 0;
    } @possible;

    my $jobs = ''; 
    foreach my $joblisting (@sorted) {
        $jobs .= $joblisting;
    }
    open EMAIL,"|$SENDMAIL" or die "cannot open $SENDMAIL: $!";
    print EMAIL <<EOL;
Subject: CL Crawler: $date
X-Oddity: The ducks in the bathroom are not mine
Content-Type: multipart/alternative; boundary="_424242_"
To: $email
From: $email

--_424242_
Content-Type: text/plain; charset="iso-8859-1"
$jobs
$errors
--_424242_
Content-Type: text/html; charset="iso-8859-1"
<html>
    <body style="font-family:'Courier New',monospace;">
    <p style="font-family:'Courier New',Courier,monospace;">
$jobs
$errors
    </p>
    </body>
</html>

--_424242_--
EOL
    close EMAIL;
}

sub get_page {
    my $url = shift;

    sleep $DELAY;
    my $browser = LWP::UserAgent->new;
    $browser->agent('Mozilla/5.0 (X11; U; Linux i686)');
    
    my $req = HTTP::Request->new(GET => $url);
    my $res = $browser->request($req);
    if ($res->is_success) {
        return $res->content;
    }
    return undef;
}

sub examine {
    my $url     = shift;
    my $title   = shift;
    my $area    = shift;

    return if ($beendone{$url});

    my $score = 0;
    my @found = ();
    my $body = get_page($url);
    return unless (defined $body);
    foreach my $keyword (keys %words) {
        my @count = $body =~ /\b$keyword\b/igs;
        if (scalar(@count) > 0) {
            my $find = $keyword . '[' . scalar(@count) . ']';
            push(@found,$find);
            #$score += scalar(@count)*$words{$keyword};
            $score += $words{$keyword};
        }
        # increase the score if the /area/ is one of the words we're looking
        # for... in this case; if the area is 'mountain view' it will get a nice
        # bonus... pushing it closer to the top of the list
        $score += $words{$keyword} if ($area =~ /$keyword/i);
    }
    print "examined: $url score: $score\n" if $debug;
    my $date  = '';
      ($date) = $body =~ /Date:\s+([0-9]{4}-[0-9]{2}-[0-9]{2})/is;
    my $fscore = sprintf("% 3i",$score);
    my $summary  = "$date: [$fscore] ($area) <a href='$url'>$title</a><br/>";
       $summary .= join(', ',@found) . '<br/><br/><br/>';
    push (@possible,$summary) if ($score > $THRESHOLD);
}

sub savedone {
    open FILE,">$OLDROOMS";
    # print the jobs we've scanned to a file, skip them if we haven't seen
    # the job in 5 iterations of this program, meaning it is no longer listed
    # on craig's list, and can be safely ignored, since a job posting is re-set
    # to 1 each time we see it with our script.
    foreach my $key (keys %beendone) {
        print FILE join("::",$key,$beendone{$key}),"\n"
            unless ($beendone{$key} > 5);
    }
    close FILE;
}

sub parse_rooms {
    my $html = shift;
    my $site = shift;

    my @rooms = $html =~ /^<p>.*(http.*font\ size.*)<\/p>$/gim;
    foreach my $room (@rooms) {
        #if (scalar(@possible) > 5) {
        #    print "possible = ".scalar(@possible) ."\n";
        #    next;
        #}
        if (scalar(@possible) >= 5000) {
            results();
            @possible = ();
        }
        my ($room,$title,$area) = $room =~ /(.*.html).*>(.*?)<\/a>.*\(([^)]*)/i;
        examine($room,$title,$area);
        # (re)set 'seen' count to 1; a low value means it is still
        # being listed on craig's list, and we still have to keep track
        # of it, to avoid double-analyzing a job listing, and potentially
        # applying multiple times for the same position.
        $beendone{$room} = 1;
        savedone();
    }
}

