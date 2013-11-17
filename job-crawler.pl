#!/usr/bin/perl
# job-crawler.pl - searches craig's list job postings and emails a summary
# Copyright (C) 2008 Christopher P. Bills (cpbills@fauxtographer.net)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;

use LWP::UserAgent;
use Getopt::Std;
use POSIX qw(strftime);

my $VERBOSE = 0;

# Email subject; 'Job Crawler YYYY-MM-DD' by default.
my $subject = "Job Crawler " . strftime("%F",localtime);

# Default configuration locations; override with -c
my $config_name = 'job-crawler.conf';
my @config_path = ();
if ($^O =~ /mswin/i) {
    @config_path = ("./${config_name}");
} else {
    @config_path = ( "/etc/${config_name}",
                     "$ENV{HOME}/.${config_name}",
                     "$ENV{HOME}/.config/${config_name}",
                     "./${config_name}" );
}
my $config_file = '';
foreach my $config (@config_path) {
    $config_file = $config if (-e "$config" && -r "$config");
}

my %opts = ();
Getopt::Std::getopts('hvc:d:e:',\%opts);

if ($opts{h}) {
    usage();
    exit 0;
}

$config_file = $opts{c} if (defined $opts{c});

my $options = read_config($config_file);
$VERBOSE = 1 if ($$options{verbose} or $opts{v});
$$options{email} = $opts{e} if (defined $opts{e});
$$options{depth} = $opts{d} if (defined $opts{d});

debug_msg("Using $config_file for configuration");

my $missing_options = verify_options($options);
if ($missing_options) {
    # exit if the options are broken
    error_msg("Required options not defined: $missing_options",1);
}

my @matches = ();

# read in previously searched job listing data...
my $history = {};
if ($$options{history} && -e "$$options{history}") {
    $history = read_history($$options{history});
}

my %results = ();
foreach my $locale (split(/\s+/,$$options{locale})) {
    my @post_urls = scrape_locale($locale,$$options{section},$$options{depth});
    foreach my $post_url (@post_urls) {
        unless ($$history{$post_url}) {
            my ($title,$area,$date,$body) = scan_post($post_url);
            if ($title && $body) {
                my ($score,$found) = score_post($title,$body,$$options{terms});
                debug_msg("score: $score\t$post_url");
                if ($score >= $$options{threshold}) {
                    $results{$post_url}{score}  = $score;
                    $results{$post_url}{region} = $area;
                    $results{$post_url}{title}  = $title;
                    $results{$post_url}{found}  = $found;
                    $results{$post_url}{date}   = $date;
                }
            } else {
                error_msg("Scanning $post_url failed",0);
            }
        }
        # Set post 'age' to 1 to indicate it is 'live'
        $$history{$post_url} = 1;
    }
}

if ($$options{history}) {
    # save URL history
    save_history($$options{history},$history,$$options{freshness});
}

my $output = format_results(\%results);

print "$output\n";

if ($output && $$options{send_email}) {
    send_mail($$options{email},$$options{sendmail},$subject,$output);
}
exit 0;

sub format_results {
    my $results     = shift;

    my $output = '';

    # sort the results by score
    my @sorted_results = sort {
        $$results{$b}{score}
            <=>
        $$results{$a}{score}
    } keys %$results;

    foreach my $result (@sorted_results) {
        my $keywords = format_keywords($$results{$result}{found});
        $output .=<<ENDL
Score:      $results{$result}{score}
Title:      $results{$result}{title}
Location:   $results{$result}{region}
URL:        $result
Date:       $results{$result}{date}
Keywords:   $keywords

ENDL
    }
    return $output;
}

sub format_keywords {
    my $kw_hash = shift;

    my @keywords = ();
    foreach my $kw (keys %$kw_hash) {
        push @keywords, "$kw\[$$kw_hash{$kw}\]";
    }
    if (scalar(@keywords) > 0) {
        my $keywords = join(', ',@keywords);
        return $keywords;
    } else {
        # this should not happen, but just in case...
        return 'No Keywords';
    }
}

sub usage {
    print qq{usage: $0 [option]...
searches craig's list postings for potential matches and can email
a summary to the user to ease job hunting process.

    -h              display this help message
    -v              verbose output
    -c <file>       specify a configuration file
    -d [0-5]        specify the depth to search
    -e <email>      specify an email address to send a summary to

};
}

sub read_config {
    # Attempts to open and read a configuration file.
    # Returns a hash-reference containing configuration details
    my $conf_file   = shift;

    my %options = ();

    if (open my $conf_fh,'<',"$conf_file") {
        # hash for the score of each search term
        my %terms   = ();

        while (<$conf_fh>) {
            my $line = $_;

            # remove pesking whitespace
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;

            # skip comments and empty lines
            next if ($line =~ /^#/);
            next if ($line =~ /^$/);

            # squish whitespace
            $line =~ s/\s+/\ /g;

            my ($option,$value) = split(/\ /,$line,2);
            if ($option eq 'locale') {
                if ($options{$option}) {
                    $options{$option} = join(' ',$options{$option},$value);
                } else {
                    $options{$option} = $value;
                }
            } elsif ($option eq 'term') {
                # Special handing for 'terms' data
                # grab the score from the end of $line and leave 'term'
                $value =~ s/\ ([-0-9]+)$//;
                $terms{"$value"} = $1;
            } else {
                if ($options{$option}) {
                    debug_msg("\'$option\' previously defined");
                }
                $options{$option} = $value;
            }
        }
        close $conf_fh;
        # Special handling for the 'terms' data
        if (scalar(keys %terms)) {
            $options{terms} = \%terms;
        } else {
            $options{terms} = 0;
        }
    } else {
        error_msg("Unable to open $conf_file: $!",1);
    }

    $options{depth} = 0 unless (defined $options{depth});
    $options{delay} = 5 unless (defined $options{delay});
    $options{threshold} = 5 unless (defined $options{threshold});

    return \%options;
}

sub error_msg {
    # Function to 'standardize' error output
    my $message = shift;
    # 0 is non-fatal, non-zero exits with that value
    my $err_lvl = shift;

    print STDERR "$message\n";
    if ($err_lvl) {
        exit $err_lvl;
    }
    return;
}

sub debug_msg {
    # Function to standardize debug output
    my $message     = shift;

    if ($VERBOSE) {
        print "$message\n";
    }
    return;
}

sub verify_options {
    # Check that required options are set, as expected.
    my $options = shift;

    my @missing = ();

    unless ($$options{terms}) {
        push @missing, 'term';
    }

    unless ($$options{locale}) {
        push @missing, 'locale';
    }

    unless ($$options{section}) {
        push @missing, 'section';
    }

    if ($$options{send_email}) {
        unless ($$options{email}) {
            $$options{send_email} = 0;
            debug_msg('No email address defined, not sending mail.');
        }
        if ($$options{sendmail}) {
            my ($bin) = split(/\s*/,$$options{sendmail});
            unless (-e "$bin" && -x "$bin") {
                $$options{send_email} = 0;
                debug_msg("Sendmail ($bin) not found, not sending mail");
            }
        } else {
            $$options{send_email} = 0;
            debug_msg('Path to sendmail not defined, not sending mail.');
        }
    }

    unless ($$options{history}) {
        $$options{history} = 0;
        debug_msg('History file undefined; not using URL history.');
    }
    if (scalar(@missing) > 0) {
        return join(' ',@missing);
    }
    return '';
}

sub read_history {
    my $hist_file = shift;

    my %history = ();
    if (open my $hist_fh,'<',$hist_file) {
        while (<$hist_fh>) {
            my $line = $_;
            chomp $line;
            my ($url,$age) = split(/::/,$line);
            # Increase the posting age to track which postings are gone
            $history{$url} = ++$age;
        }
        close $hist_fh;
    } else {
        error_msg("Failed to open $hist_file: $!",0);
    }

    # return a hash reference (for easier passing between functions...)
    return \%history;
}

sub send_mail {
    my $email_addr  = shift;
    my $sendmail    = shift;
    my $subject     = shift;
    my $results     = shift;

    my $email_content = qq{Subject: $subject
X-Oddity: The ducks in the bathroom are not mine
To: $email_addr
From: $email_addr
Content-Type: text/plain; charset="iso-8859-1"

$results
};

    debug_msg("Sending email to $email_addr");
    debug_msg("$email_content");

    if (open my $email_pipe,'|-',"$sendmail") {
        print $email_pipe $email_content;
        close $email_pipe;
    } else {
        error_msg("Cannot open $sendmail: $!",0);
    }
}

sub get_page {
    my $url = shift;

    my $browser = LWP::UserAgent->new;
    $browser->agent('Mozilla/5.0 (X11; U; Linux i686)');

    my $req = HTTP::Request->new(GET => $url);
    my $res = $browser->request($req);
    if ($res->is_success) {
        sleep $$options{delay};
        return $res->content;
    }
    error_msg("Problem fetching $url ($!)",0);
    return;
}

sub scrape_locale {
    # Scrape postings in a provided region and section
    my $region  = shift;
    my $section = shift;
    my $depth   = shift;

    # Currently CL has static URLs for 1-100, 101-200, 201-300, etc postings
    my @depths = qw(
        / /index100.html /index200.html /index300.html
        /index400.html /index500.html
    );
    my $region_url = "http://$region.craigslist.org";

    # hash for getting rid of duplicate post URLs
    my %unique_posts = ();

    for my $depth ( 0 .. $depth ) {
        my $posts_url = "$region_url/$section" . "$depths[$depth]";
        my $postings = get_page("$posts_url");
        if ($postings) {
            # Scrape HTML for post URLs
            # posting URLs are 10 digits then .html
            my @relative_urls = ($postings =~ /"(\/[^"]*[0-9]+\.html)"/gim);
            my @absolute_urls = ($postings =~ /"(http[^"]*[0-9]+\.html)"/gim);

            foreach my $url (@relative_urls) {
                $unique_posts{"$region_url$url"} = 1;
            }
            foreach my $url (@absolute_urls) {
                $unique_posts{"$url"} = 1;
            }
        } else {
            debug("failed to scrape posts: $! ($posts_url)",0);
        }
    }
    return keys %unique_posts;
}

sub score_post {
    # Scans the text of the post for keywords
    # Inputs: post title, post body, hashref of scores
    # Output: the post's score and a hash of found keywords

    my $title   = shift;
    my $body    = shift;
    my $scores  = shift;

    my %found   = ();
    my $score   = 0;

    foreach my $term (keys %$scores) {
        my @matches = $body =~ /\b$term\b/gis;
        my $count = scalar(@matches);
        if ($count > 0) {
            $found{$term} = $count;
            $score += $count * $$scores{$term};
        }
        if ($title && $title =~ /$term/i) {
            $score += $$scores{$term};
        }
    }
    return ($score,\%found);
}

sub scan_post {
    # Scan a Craig's List posting for configured search terms
    # Returns a summary if the post meets score requirement

    # This function makes a few assumptions about the CL post's format.
    # This function may need to be frequently revised.
    my $url     = shift;
    my $scores  = shift;

    my $score   = 0;

    # Terms found in job posting
    my @found = ();

    my $title   = 'No Title';
    my $region  = '???';
    my $date    = '????-??-??';

    my $body    = get_page($url);
    unless (defined $body) {
        return (0,0,0,0);
    }

    if ($body =~ /<title>(.*?)<\/title>/gi) {
        $title = $1;
    }

    if ($body =~ /postingTitle = "([^"]*)/gi) {
        $region = $1;
    }
    # Quote the $title contents, in case they contain ()s and other chars
    $region =~ s/^\Q$title\E\s*//;
    # Remove the first and last parens from $region
    $region =~ s/^\(//;
    $region =~ s/\)$//;

    if ($body =~ /datetime="([0-9]{4}-[0-9]{2}-[0-9]{2})/gi) {
        $date = $1;
    }

    # Drop everything leading up to the post content
    $body =~ s/^.*\<section id=\"postingbody\"\>//gis;
    # Drop everything after the post content
    $body =~ s/\<\/section\>.*//gis;

    return ($title, $region, $date, $body);
}

sub save_history {
    # Keep track of 'fresh' jobs that have been scanned already.
    # If a posting hasn't been seen in a set number of program runs,
    # it is no longer tracked. This keeps the history file from growing
    # too large and tracking irellevant data.
    my $hist_file   = shift;
    my $postings    = shift;
    my $freshness   = shift;

    if (open my $hist_fh,'>',"$hist_file") {
        foreach my $url (keys %$postings) {
            if ($freshness > $$postings{$url}) {
                print $hist_fh join('::',$url,$$postings{$url}),"\n";
            }
        }
        close $hist_fh;
    } else {
        # Be noisy about our inability to track things.
        error_msg("Unable to open $hist_file for writing; $!",0);
    }
}
