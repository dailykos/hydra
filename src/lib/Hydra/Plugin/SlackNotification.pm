package Hydra::Plugin::SlackNotification;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use JSON;

=head1 NAME

SlackNotification - hydra-notify plugin for sending Slack notifications about
build results

=head1 DESCRIPTION

This plugin reports build statuses to various Slack channels. One can configure
which builds are reported to which channels, and whether reports should be on
state change (regressions and improvements), or for each build.

=head1 CONFIGURATION

The module is configured using the C<slack> block in Hydra's config file. There
can be multiple such blocks in the config file, each configuring different (or
even the same) set of builds and how they report to Slack channels.

The following entries are recognized in the C<slack> block:

=over 4

=item jobs

A pattern for job names. All builds whose job name matches this pattern will
emit a message to the designated Slack channel (see C<url>). The pattern will
match the whole name, thus leaving this field empty will result in no
notifications being sent. To match on all builds, use C<.*>.

=item url

The URL to a L<Slack incoming webhook|https://api.slack.com/messaging/webhooks>.

Slack administrators have to prepare one incoming webhook for each channel. This
URL should be treated as secret, as anyone knowing the URL could post a message
to the Slack workspace (or more precisely, the channel behind it).

=item force

(Optional) An I<integer> indicating whether to report on every build or only on
changes in the status. If not provided, defaults to 0, that is, sending reports
only when build status changes from success to failure, and vice-versa. Any
other value results in reporting on every build.

=back

=cut

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{slack};
}

sub renderDuration {
    my ($build) = @_;
    my $duration = $build->stoptime - $build->starttime;
    my $res = "";
    if ($duration >= 24*60*60) {
       $res .= ($duration / (24*60*60)) . "d";
    }
    if ($duration >= 60*60) {
        $res .= (($duration / (60*60)) % 24) . "h";
    }
    if ($duration >= 60) {
        $res .= (($duration / 60) % 60) . "m";
    }
    $res .= ($duration % 60) . "s";
    return $res;
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $cfg = $self->{config}->{slack};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    print STDERR "SlackNotification_Debug Received message for $build\n";

    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Figure out to which channelss to send notification.  For each channel
    # we send one aggregate message.
    my %channels;
    foreach my $b ($build, @{$dependents}) {
        my $jobName = showJobName $b;
        my $buildStatus = $b->buildstatus;
        my $cancelledOrAborted = $buildStatus == 4 || $buildStatus == 3;

        my $prevBuild = getPreviousBuild($b);
        my $sameAsPrevious = defined $prevBuild && ($buildStatus == $prevBuild->buildstatus);
        my $prevBuildStatus = (defined $prevBuild) ? $prevBuild->buildstatus : -1;
        my $prevBuildId = (defined $prevBuild) ? $prevBuild->id : -1;

        print STDERR "SlackNotification_Debug job name $jobName status $buildStatus (previous: $prevBuildStatus from $prevBuildId)\n";

        foreach my $channel (@config) {
            next unless $jobName =~ /^$channel->{jobs}$/;

            my $force = $channel->{force};

            print STDERR "SlackNotification_Debug found match with '$channel->{jobs}' with force=$force\n";

            # If build is cancelled or aborted, do not send Slack notification.
            next if ! $force && $cancelledOrAborted;

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send Slack notification.
            next if ! $force && $sameAsPrevious;

            print STDERR "SlackNotification_Debug adding $jobName to the report list\n";
            $channels{$channel->{url}} //= { channel => $channel, builds => [] };
            push @{$channels{$channel->{url}}->{builds}}, $b;
        }
    }

    return if scalar keys %channels == 0;

    my ($authors, $nrCommits) = getResponsibleAuthors($build, $self->{plugins});

    # Send a message to each room.
    foreach my $url (keys %channels) {
        my $channel = $channels{$url};
        my @deps = grep { $_->id != $build->id } @{$channel->{builds}};

        my $imgBase = $baseurl;
        my $img =
            $build->buildstatus == 0 ? "$imgBase/static/images/checkmark_128.png" :
            $build->buildstatus == 2 ? "$imgBase/static/images/dependency_128.png" :
            $build->buildstatus == 4 ? "$imgBase/static/images/cancelled_128.png" :
            "$imgBase/static/images/error_128.png";

        my $color =
            $build->buildstatus == 0 ? "good" :
            $build->buildstatus == 4 ? "warning" :
            "danger";

        my $text = "";
        my $title = "";

        #if job begin or complete, use different text
        if ($build->get_column('project') =~ /(.*)-deploy/) {
            $text .= "<$baseurl/eval/" . getFirstEval($build)->id . "|Deploy for $1, ";
            $title .= "Deploy $1";
            $build->get_column('jobset') =~ /deploy-(.*)/;
            $text .= "$1>";
            $title .= ", $1";

            if ($build->get_column('job') =~ /.*begin.*/) {
              $text .= " has started ";
	      $color = "gray";
            }
            if ($build->get_column('job') =~ /.*complete.*/) {
              if ($build->buildstatus == 0) { 
                $text .= " has finished";
              } else {
                $text .= " has failed";
              }
            }
        } else {
          $text .= "Job <$baseurl/job/${\$build->get_column('project')}/${\$build->get_column('jobset')}/${\$build->get_column('job')}|${\showJobName($build)}>";
          $text .= ":" . showStatus($build);
          $title .= "Job " . showJobName($build) . " build number " . $build->id;
        }

        if (scalar keys %{$authors} > 0) {
            # FIXME: escaping
            my @x = map { "$_" } (keys %{$authors});
            $text .= ", possibly by ";
            $text .= join(" or ", scalar @x > 1 ? join(", ", @x[0..scalar @x - 2]) : (), $x[-1]);
        }
        print STDERR "SlackNotification_Debug POSTing to url ending with: ${\substr $url, -8}\n";


        my $msg =
        { attachments =>
          [{ fallback => "Job " . showJobName($build) . ": " . showStatus($build),
            text => $text,
            thumb_url => $img,
	    color => $color,
            title => $title,
            title_link => "$baseurl/eval/" . getFirstEval($build)->id
          }]
        };

        my $req = HTTP::Request->new('POST', $url);
        $req->header('Content-Type' => 'application/json');
        $req->content(encode_json($msg));
        my $ua = LWP::UserAgent->new();
        $ua->request($req);
    }
}

1;
