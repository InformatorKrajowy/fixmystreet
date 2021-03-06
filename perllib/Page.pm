#!/usr/bin/perl
#
# Page.pm:
# Various HTML stuff for the FixMyStreet site.
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Page.pm,v 1.230 2010-01-15 17:08:55 matthew Exp $
#

package Page;

use strict;
use Carp;
use mySociety::CGIFast qw(-no_xhtml);
use Error qw(:try);
use File::Slurp;
use HTTP::Date; # time2str
use Image::Magick;
use Image::Size;
use POSIX qw(strftime);
use URI::Escape;
use Text::Template;

use Memcached;
use Problems;
use Cobrand;

use mySociety::Config;
use mySociety::DBHandle qw/dbh select_all/;
use mySociety::EvEl;
use mySociety::Locale;
use mySociety::MaPit;
use mySociety::TempFiles;
use mySociety::WatchUpdate;
use mySociety::Web qw(ent);

BEGIN {
    (my $dir = __FILE__) =~ s{/[^/]*?$}{};
    mySociety::Config::set_file("$dir/../conf/general");
}

# Under the BEGIN so that the config has been set.
use FixMyStreet::Map;

my $lastmodified;

sub do_fastcgi {
    my ($func, $lm) = @_;

    try {
        my $W = new mySociety::WatchUpdate();
        while (my $q = new mySociety::Web()) {
            next if $lm && $q->Maybe304($lm);
            $lastmodified = $lm;
            microsite($q);
            &$func($q);
            dbh()->rollback() if $mySociety::DBHandle::conf_ok;
            $W->exit_if_changed();
        }
    } catch Error::Simple with {
        report_error(@_);
    } catch Error with {
        report_error(@_);
    };
    dbh()->rollback() if $mySociety::DBHandle::conf_ok;
    exit(0);
}

sub report_error {
    my $E = shift;
    my $msg = sprintf('%s:%d: %s', $E->file(), $E->line(), CGI::escapeHTML($E->text()));
    warn "caught fatal exception: $msg";
    warn "aborting";
    ent($msg);
    my $contact_email = mySociety::Config::get('CONTACT_EMAIL');
    my $trylater = sprintf(_('Please try again later, or <a href="mailto:%s">email us</a> to let us know.'), $contact_email);
    my $somethingwrong = _("Sorry! Something's gone wrong.");
    my $errortext = _("The text of the error was:");
    print "Status: 500\nContent-Type: text/html; charset=iso-8859-1\n\n",
            qq(<html><head><title>$somethingwrong</title></head></html>),
            q(<body>),
            qq(<h1>$somethingwrong</h1>),
            qq(<p>$trylater</p>),
            q(<hr>),
            qq(<p>$errortext</p>),
            qq(<blockquote class="errortext">$msg</blockquote>),
            q(</body></html>);
}

=item microsite Q

Work out what site we're on, template appropriately

=cut
sub microsite {
    my $q = shift;
    my $host = $ENV{HTTP_HOST} || '';
    $q->{site} = 'fixmystreet';
    my $allowed_cobrands = Cobrand::get_allowed_cobrands();
    foreach my $cobrand (@{$allowed_cobrands}){
        $q->{site} = $cobrand if $host =~ /$cobrand/;
    }

    my $lang;
    $lang = 'cy' if $host =~ /cy/;
    $lang = 'en-gb' if $host =~ /^en\./;
    Cobrand::set_lang_and_domain(get_cobrand($q), $lang);

    Problems::set_site_restriction($q);
    Memcached::set_namespace(mySociety::Config::get('BCI_DB_NAME') . ":");
}
=item get_cobrand Q

Return the cobrand for a query

=cut
sub get_cobrand {
    my $q = shift;
    my $cobrand = '';
    $cobrand = $q->{site} if $q->{site} ne 'fixmystreet';
    return $cobrand;
}

=item base_url_with_lang Q REVERSE EMAIL

Return the base URL for the site. Reverse the language component if REVERSE is set to one. If EMAIL is set to
one, return the base URL to use in emails.

=cut

sub base_url_with_lang {
    my ($q, $reverse, $email) = @_;
    my $base;
    my $cobrand = get_cobrand($q);
    if ($email) {
        $base = Cobrand::base_url_for_emails($cobrand, Cobrand::extra_data($cobrand, $q));
    } else {
        $base = Cobrand::base_url($cobrand);
    }
    return $base unless $q->{site} eq 'emptyhomes';
    my $lang = $mySociety::Locale::lang;
    if ($reverse && $lang eq 'en-gb') {
        $base =~ s{http://}{$&cy.};
    } elsif ($reverse) {
        $base =~ s{http://}{$&en.};
    } elsif ($lang eq 'cy') {
        $base =~ s{http://}{$&cy.};
    } else {
        $base =~ s{http://}{$&en.};
    }
    return $base;
}

=item template_root 

Returns the path from which template files will be read. 

=cut 

sub template_root($;$) {
    my ($q, $fallback) = @_;
    return '/../templates/website/' if $q->{site} eq 'fixmystreet' || $fallback;
    return '/../templates/website/cobrands/' . $q->{site} . '/';
}

=item template_vars QUERY PARAMS

Return a hash of variables that can be substituted into header and footer templates.
QUERY is the incoming request
PARAMS contains a few things used to generate variables, such as lang, title, and rss.

=cut

sub template_vars ($%) {
    my ($q, %params) = @_;
    my %vars;
    my $host = base_url_with_lang($q, undef);
    my $lang_url = base_url_with_lang($q, 1);
    $lang_url .= $ENV{REQUEST_URI} if $ENV{REQUEST_URI};

    my $site_title = $q->{site} eq 'fixmystreet'
        ? _('FixMyStreet')
        : Cobrand::site_title(get_cobrand($q));

    %vars = (
        'report' => _('Report a problem'),
        'reports' => _('All reports'),
        'alert' => _('Local alerts'),
        'faq' => _('Help'),
        'about' => _('About us'),
        'site_title' => $site_title,
        'host' => $host,
        'lang_code' => $params{lang},
        'lang' => $params{lang} eq 'en-gb' ? 'Cymraeg' : 'English',
        'lang_url' => $lang_url,
        'title' => $params{title},
        'rss' => '',
        map_js => FixMyStreet::Map::header_js(),
    );

    if ($params{rss}) {
        $vars{rss} = '<link rel="alternate" type="application/rss+xml" title="' . $params{rss}[0] . '" href="' . $params{rss}[1] . '">';
    }

    if ($params{robots}) {
        $vars{robots} = '<meta name="robots" content="' . $params{robots} . '">';
    }

    if ($q->{site} eq 'fixmystreet') {
        my $home = !$params{title} && $ENV{SCRIPT_NAME} eq '/index.cgi' && !$ENV{QUERY_STRING};
        $vars{heading_element_start} = $home ? '<h1 id="header">' : '<div id="header"><a href="/">';
        $vars{heading} = _('Fix<span id="my">My</span>Street');
        $vars{heading_element_end} = $home ? '</h1>' : '</a></div>';
    }

    return \%vars;
}

=item template Q [PARAM VALUE ...]

Return the correct template given PARAMs

=cut
sub template($%){
    my ($q, %params) = @_;        
    my $template;
    if ($params{template}){
        $template = $params{template};
    }else{
        $template = $q->{site};
    }
    return $template;
}

=item template_include

Return HTML for a template, given a template name, request,
template root, and any parameters needed.

=cut

sub template_include {
    my ($template, $q, $template_root, %params) = @_;
    (my $file = __FILE__) =~ s{/[^/]*?$}{};
    my $template_file = $file . $template_root . $template;
    $template_file = $file . template_root($q, 1) . $template unless -e $template_file;
    return undef unless -e $template_file;

    $template = Text::Template->new(
        SOURCE => $template_file,
        DELIMITERS => ['{{', '}}'],
    );
    return $template->fill_in(HASH => \%params);
}

=item template_header TEMPLATE Q ROOT PARAMS

Return HTML for the templated top of a page, given a 
template name, request, template root, and parameters.

=cut

sub template_header($$$%) {
    my ($template, $q, $template_root, %params) = @_;
    $template = $q->{site} eq 'fixmystreet'
        ? 'header'
        : $template . '-header';
    my $vars = template_vars($q, %params);
    return template_include($template, $q, $template_root, %$vars);
}

=item header Q [PARAM VALUE ...]

Return HTML for the top of the page, given PARAMs (TITLE is required).

=cut
sub header ($%) {
    my ($q, %params) = @_;
    my  $context = $params{context};
    my $default_params = Cobrand::header_params(get_cobrand($q), $q, %params);
    my %default_params = %{$default_params};
    %params = (%default_params, %params);
    my %permitted_params = map { $_ => 1 } qw(title rss expires lastmodified template cachecontrol context status_code robots);
    foreach (keys %params) {
        croak "bad parameter '$_'" if (!exists($permitted_params{$_}));
    }

    my %head = ();
    $head{-expires} = $params{expires} if $params{expires};
    $head{'-last-modified'} = time2str($params{lastmodified}) if $params{lastmodified};
    $head{'-last-modified'} = time2str($lastmodified) if $lastmodified;
    $head{'-Cache-Control'} = $params{cachecontrol} if $params{cachecontrol};
    $head{'-status'} = $params{status_code} if $params{status_code};
    print $q->header(%head);

    $params{title} ||= '';
    $params{title} .= ' - ' if $params{title};
    $params{title} = ent($params{title});
    $params{lang} = $mySociety::Locale::lang;

    my $template = template($q, %params);
    my $html = template_header($template, $q, template_root($q), %params);
    my $cache_val = $default_params{cachecontrol};
    if (mySociety::Config::get('STAGING_SITE')) {
        $html .= '<p class="error">' . _("This is a developer site; things might break at any time, and the database will be periodically deleted.") . '</p>';
    }
    return $html;
}

=item footer

=cut
sub footer {
    my ($q, %params) = @_;

    if ($q->{site} ne 'fixmystreet') {
        my $template = template($q, %params) . '-footer';
        my $template_root = template_root($q);
        my $html = template_include($template, $q, $template_root, %params);
        my $lang = $mySociety::Locale::lang;
        if ($q->{site} eq 'emptyhomes' && $lang eq 'cy') {
            $html =~ s/25 Walter Road<br>Swansea/25 Heol Walter<br>Abertawe/;
        }
        return $html;
    }

    my $pc = $q->param('pc') || '';
    $pc = "?pc=" . ent($pc) if $pc;

    my $piwik = "";
    if (mySociety::Config::get('BASE_URL') eq "http://www.fixmystreet.com") {
        $piwik = <<EOF;
<!-- Piwik -->
<script type="text/javascript">
var pkBaseURL = (("https:" == document.location.protocol) ? "https://piwik.mysociety.org/" : "http://piwik.mysociety.org/");
document.write(unescape("%3Cscript src='" + pkBaseURL + "piwik.js' type='text/javascript'%3E%3C/script%3E"));
</script><script type="text/javascript">
try {
var piwikTracker = Piwik.getTracker(pkBaseURL + "piwik.php", 8);
piwikTracker.trackPageView();
piwikTracker.enableLinkTracking();
} catch( err ) {}
</script><noscript><p><img src="http://piwik.mysociety.org/piwik.php?idsite=8" style="border:0" alt=""/></p></noscript>
<!-- End Piwik Tag -->
EOF
    }

    my $navigation = _('Navigation');
    my $report = _("Report a problem");
    my $reports = _("All reports");
    my $alerts = _("Local alerts");
    my $help = _("Help");
    my $contact = _("Contact");
    my $orglogo = _('<a href="http://www.mysociety.org/"><img id="logo" width="133" height="26" src="/i/mysociety-dark.png" alt="View mySociety.org"><span id="logoie"></span></a>');
    my $creditline = _('Built by <a href="http://www.mysociety.org/">mySociety</a>, using some <a href="http://github.com/mysociety/fixmystreet">clever</a>&nbsp;<a href="https://secure.mysociety.org/cvstrac/dir?d=mysociety/services/TilMa">code</a>.');

    return <<EOF;
</div></div>
<h2 class="v">$navigation</h2>
<ul id="navigation">
<li><a href="/">$report</a></li>
<li><a href="/reports">$reports</a></li>
<li><a href="/alert$pc">$alerts</a></li>
<li><a href="/faq">$help</a></li>
<li><a href="/contact">$contact</a></li>
</ul>

$orglogo

<p id="footer">$creditline</p>

$piwik

</body>
</html>
EOF
}

=item error_page Q MESSAGE

=cut
sub error_page ($$) {
    my ($q, $message);
    my $html = header($q, title=>_("Error"))
            . $q->p($message)
            . footer($q);
    print $q->header(-content_length => length($html)), $html;
}

# send_email TO (NAME) TEMPLATE-NAME PARAMETERS
# TEMPLATE-NAME is currently one of problem, update, alert, tms
sub send_email {
    my ($q, $email, $name, $thing, %h) = @_;
    my $file_thing = $thing;
    $file_thing = 'empty property' if $q->{site} eq 'emptyhomes' && $thing eq 'problem'; # Needs to be in English
    my $template = "$file_thing-confirm";
    $template = File::Slurp::read_file("$FindBin::Bin/../templates/emails/$template");
    my $to = $name ? [[$email, $name]] : $email;
    my $cobrand = get_cobrand($q);
    my $sender = Cobrand::contact_email($cobrand);
    my $sender_name = Cobrand::contact_name($cobrand);
    $sender =~ s/team/fms-DO-NOT-REPLY/;
    mySociety::EvEl::send({
        _template_ => _($template),
        _parameters_ => \%h,
        From => [ $sender, _($sender_name)],
        To => $to,
    }, $email);

    my ($action, $worry);
    if ($thing eq 'problem') {
        $action = _('your problem will not be posted');
        $worry = _("we'll hang on to your problem report while you're checking your email.");
    } elsif ($thing eq 'update') {
        $action = _('your update will not be posted');
        $worry = _("we'll hang on to your update while you're checking your email.");
    } elsif ($thing eq 'alert') {
        $action = _('your alert will not be activated');
        $worry = _("we'll hang on to your alert while you're checking your email.");
    } elsif ($thing eq 'tms') {
        $action = 'your expression of interest will not be registered';
        $worry = "we'll hang on to your expression of interest while you're checking your email.";
    }

    my $out = sprintf(_(<<EOF), $action, $worry);
<h1>Nearly Done! Now check your email...</h1>
<p>The confirmation email <strong>may</strong> take a few minutes to arrive &mdash; <em>please</em> be patient.</p>
<p>If you use web-based email or have 'junk mail' filters, you may wish to check your bulk/spam mail folders: sometimes, our messages are marked that way.</p>
<p>You must now click the link in the email we've just sent you &mdash;
if you do not, %s.</p>
<p>(Don't worry &mdash; %s)</p>
EOF

    my %vars = (
        action => $action,
        worry => $worry,
        url_home => Cobrand::url($cobrand, '/', $q),
    );
    my $cobrand_email = Page::template_include('check-email', $q, Page::template_root($q), %vars);
    return $cobrand_email if $cobrand_email;
    return $out;
}

sub prettify_epoch {
    my ($q, $s, $short) = @_;
    my $cobrand = get_cobrand($q);
    my $cobrand_datetime = Cobrand::prettify_epoch($cobrand, $s);
    return $cobrand_datetime if ($cobrand_datetime);
    my @s = localtime($s);
    my $tt = strftime('%H:%M', @s);
    my @t = localtime();
    if (strftime('%Y%m%d', @s) eq strftime('%Y%m%d', @t)) {
        $tt = "$tt " . _('today');
    } elsif (strftime('%Y %U', @s) eq strftime('%Y %U', @t)) {
        $tt = "$tt, " . strftime('%A', @s);
    } elsif ($short) {
        $tt = "$tt, " . strftime('%e %b %Y', @s);
    } elsif (strftime('%Y', @s) eq strftime('%Y', @t)) {
        $tt = "$tt, " . strftime('%A %e %B %Y', @s);
    } else {
        $tt = "$tt, " . strftime('%a %e %B %Y', @s);
    }
    return $tt;
}

# argument is duration in seconds, rounds to the nearest minute
sub prettify_duration {
    my ($s, $nearest) = @_;
    if ($nearest eq 'week') {
        $s = int(($s+60*60*24*3.5)/60/60/24/7)*60*60*24*7;
    } elsif ($nearest eq 'day') {
        $s = int(($s+60*60*12)/60/60/24)*60*60*24;
    } elsif ($nearest eq 'hour') {
        $s = int(($s+60*30)/60/60)*60*60;
    } elsif ($nearest eq 'minute') {
        $s = int(($s+30)/60)*60;
        return _('less than a minute') if $s == 0;
    }
    my @out = ();
    _part(\$s, 60*60*24*7, _('week'), \@out);
    _part(\$s, 60*60*24, _('day'), \@out);
    _part(\$s, 60*60, _('hour'), \@out);
    _part(\$s, 60, _('minute'), \@out);
    return join(', ', @out);
}
sub _part {
    my ($s, $m, $w, $o) = @_;
    if ($$s >= $m) {
        my $i = int($$s / $m);
        push @$o, "$i $w" . ($i != 1 ? 's' : '');
        $$s -= $i * $m;
    }
}

sub display_problem_meta_line($$) {
    my ($q, $problem) = @_;
    my $out = '';
    my $date_time = prettify_epoch($q, $problem->{time});
    if ($q->{site} eq 'emptyhomes') {
        my $category = _($problem->{category});
        utf8::decode($category); # So that Welsh to Welsh doesn't encode already-encoded UTF-8
        if ($problem->{anonymous}) {
            $out .= sprintf(_('%s, reported anonymously at %s'), ent($category), $date_time);
        } else {
            $out .= sprintf(_('%s, reported by %s at %s'), ent($category), ent($problem->{name}), $date_time);
        }
    } else {
        if ($problem->{service} && $problem->{category} && $problem->{category} ne 'Other' && $problem->{anonymous}) {
            $out .= sprintf(_('Reported by %s in the %s category anonymously at %s'), ent($problem->{service}), ent($problem->{category}), $date_time);
        } elsif ($problem->{service} && $problem->{category} && $problem->{category} ne 'Other') {
            $out .= sprintf(_('Reported by %s in the %s category by %s at %s'), ent($problem->{service}), ent($problem->{category}), ent($problem->{name}), $date_time);
        } elsif ($problem->{service} && $problem->{anonymous}) {
            $out .= sprintf(_('Reported by %s anonymously at %s'), ent($problem->{service}), $date_time);
        } elsif ($problem->{service}) {
            $out .= sprintf(_('Reported by %s by %s at %s'), ent($problem->{service}), ent($problem->{name}), $date_time);
        } elsif ($problem->{category} && $problem->{category} ne 'Other' && $problem->{anonymous}) {
            $out .= sprintf(_('Reported in the %s category anonymously at %s'), ent($problem->{category}), $date_time);
        } elsif ($problem->{category} && $problem->{category} ne 'Other') {
            $out .= sprintf(_('Reported in the %s category by %s at %s'), ent($problem->{category}), ent($problem->{name}), $date_time);
        } elsif ($problem->{anonymous}) {
            $out .= sprintf(_('Reported anonymously at %s'), $date_time);
        } else {
            $out .= sprintf(_('Reported by %s at %s'), ent($problem->{name}), $date_time);
        }
    }
    my $cobrand = get_cobrand($q);
    $out .= Cobrand::extra_problem_meta_text($cobrand, $problem);
    $out .= '; ' . _('the map was not used so pin location may be inaccurate') unless ($problem->{used_map});
    if ($problem->{council}) {
        if ($problem->{whensent}) {
            $problem->{council} =~ s/\|.*//g;
            my @councils = split /,/, $problem->{council};
            my $areas_info = mySociety::MaPit::call('areas', \@councils);
            my $council = join(' and ', map { $areas_info->{$_}->{name} } @councils);
            $out .= '<small class="council_sent_info">';
            $out .= $q->br() . sprintf(_('Sent to %s %s later'), $council, prettify_duration($problem->{whensent}, 'minute'));
            $out .= '</small>';
        }
    } else {
        $out .= $q->br() . $q->small(_('Not reported to council'));
    }
    return $out;
}

sub display_problem_detail($) {
    my $problem = shift;
    (my $detail = $problem->{detail}) =~ s/\r//g;
    my $out = '';
    foreach (split /\n{2,}/, $detail) {
        $out .= '<p>' . ent($_) . '</p>';
    }
    return $out;
}

sub display_problem_photo($$) {
    my ($q, $problem) = @_;
    my $cobrand = get_cobrand($q);
    my $display_photos = Cobrand::allow_photo_display($cobrand);
    if ($display_photos && $problem->{photo}) {
        my $dims = Image::Size::html_imgsize(\$problem->{photo});
        return "<p align='center'><img alt='' $dims src='/photo?id=$problem->{id}'></p>";
    }
    return '';
}

# Display information about problem
sub display_problem_text($$) {
    my ($q, $problem) = @_;

    my $out = $q->h1(ent($problem->{title}));
    $out .= '<p><em>';
    $out .= display_problem_meta_line($q, $problem);
    $out .= '</em></p>';
    $out .= display_problem_detail($problem);
    $out .= display_problem_photo($q, $problem);
    return $out;
}

# Display updates
sub display_problem_updates($$) {
    my ($id, $q) = @_;
    my $cobrand = get_cobrand($q);
    my $updates = select_all(
        "select id, name, extract(epoch from confirmed) as confirmed, text,
         mark_fixed, mark_open, photo, cobrand
         from comment where problem_id = ? and state='confirmed'
         order by confirmed", $id);
    my $out = '';
    if (@$updates) {
        $out .= '<div id="updates">';
        $out .= '<h2 class="problem-update-list-header">' . _('Updates') . '</h2>';
        foreach my $row (@$updates) {
            $out .= "<div><div class=\"problem-update\"><p><a name=\"update_$row->{id}\"></a><em>";
            if ($row->{name}) {
                $out .= sprintf(_('Posted by %s at %s'), ent($row->{name}), prettify_epoch($q, $row->{confirmed}));
            } else {
                $out .= sprintf(_('Posted anonymously at %s'), prettify_epoch($q, $row->{confirmed}));
            }
            $out .= Cobrand::extra_update_meta_text($cobrand, $row);
            $out .= ', ' . _('marked as fixed') if ($row->{mark_fixed});
            $out .= ', ' . _('reopened') if ($row->{mark_open});
            $out .= '</em></p>';

            my $allow_update_reporting = Cobrand::allow_update_reporting($cobrand);
            if ($allow_update_reporting) {
                my $contact = '/contact?id=' . $id . ';update_id='. $row->{id};
                my $contact_url =  Cobrand::url($cobrand, $contact, $q);
                $out .= '<p>';
                $out .= $q->a({rel => 'nofollow', class => 'unsuitable-problem', href => $contact_url}, _('Offensive? Unsuitable? Tell us'));
                $out .= '</p>';
            }
            $out .= '</div>';
            $out .= '<div class="update-text">';
            my $text = $row->{text};
            $text =~ s/\r//g;
            foreach (split /\n{2,}/, $text) {
                $out .= '<p>' . ent($_) . '</p>';
            }
            my $cobrand = get_cobrand($q);
            my $display_photos = Cobrand::allow_photo_display($cobrand);
            if ($display_photos && $row->{photo}) {
                my $dims = Image::Size::html_imgsize(\$row->{photo});
                $out .= "<p><img alt='' $dims src='/photo?c=$row->{id}'></p>";
            }
            $out .= '</div>';
            $out .= '</div>';
        }
        $out .= '</div>';
    }
    return $out;
}

sub mapit_check_error {
    my $location = shift;
    if ($location->{error}) {
        return _('That postcode was not recognised, sorry.') if $location->{code} =~ /^4/;
        return $location->{error};
    }
    my $island = $location->{coordsyst};
    if (!$island) {
        return _("Sorry, that appears to be a Crown dependency postcode, which we don't cover.");
    }
    if ($island eq 'I') {
        return _("We do not cover Northern Ireland, I'm afraid, as our licence doesn't include any maps for the region.");
    }
    return 0;
}

sub short_name {
    my $name = shift;
    # Special case Durham as it's the only place with two councils of the same name
    return 'Durham+County' if ($name eq 'Durham County Council');
    return 'Durham+City' if ($name eq 'Durham City Council');
    $name =~ s/ (Borough|City|District|County) Council$//;
    $name =~ s/ Council$//;
    $name =~ s/ & / and /;
    $name = URI::Escape::uri_escape_utf8($name);
    $name =~ s/%20/+/g;
    return $name;
}

sub check_photo {
    my ($q, $fh) = @_;
    my $ct = $q->uploadInfo($fh)->{'Content-Type'};
    my $cd = $q->uploadInfo($fh)->{'Content-Disposition'};
    # Must delete photo param, otherwise display functions get confused
    $q->delete('photo');
    return _('Please upload a JPEG image only') unless
        ($ct eq 'image/jpeg' || $ct eq 'image/pjpeg');
    return '';
}

sub process_photo {
    my $fh = shift;
    my $import = shift;

    my $blob = join('', <$fh>);
    close $fh;
    my ($handle, $filename) = mySociety::TempFiles::named_tempfile('.jpeg');
    print $handle $blob;
    close $handle;

    my $photo = Image::Magick->new;
    my $err = $photo->Read($filename);
    unlink $filename;
    throw Error::Simple("read failed: $err") if "$err";
    $err = $photo->Scale(geometry => "250x250>");
    throw Error::Simple("resize failed: $err") if "$err";
    my @blobs = $photo->ImageToBlob();
    undef $photo;
    $photo = $blobs[0];
    return $photo unless $import; # Only check orientation for iPhone imports at present

    # Now check if it needs orientating
    ($fh, $filename) = mySociety::TempFiles::named_tempfile('.jpeg');
    print $fh $photo;
    close $fh;
    my $out = `jhead -se -autorot $filename`;
    if ($out) {
        open(FP, $filename) or throw Error::Simple($!);
        $photo = join('', <FP>);
        close FP;
    }
    unlink $filename;
    return $photo;
}

sub scambs_categories {
    return ('Abandoned vehicles', 'Discarded hypodermic needles',
            'Dog fouling', 'Flytipping', 'Graffiti', 'Lighting (e.g. security lights)',
            'Litter', 'Neighbourhood noise');
}

1;
