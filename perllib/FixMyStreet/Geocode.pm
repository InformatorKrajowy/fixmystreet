#!/usr/bin/perl
#
# FixMyStreet::Geocode
# The geocoding functions for FixMyStreet.
#
# Copyright (c) 2010 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/

package FixMyStreet::Geocode;

use strict;
use Error qw(:try);
use File::Slurp;
use LWP::Simple;
use Digest::MD5 qw(md5_hex);
use URI::Escape;

use Cobrand;
use Page;
use mySociety::Config;
use mySociety::GeoUtil;
use mySociety::MaPit;
use mySociety::PostcodeUtil;
use mySociety::Web qw(NewURL);

BEGIN {
    (my $dir = __FILE__) =~ s{/[^/]*?$}{};
    mySociety::Config::set_file("$dir/../../conf/general");
}

# lookup STRING QUERY
# Given a user-inputted string, try and convert it into co-ordinates using either
# MaPit if it's a postcode, or Google Maps API otherwise. Returns an array of
# data, including an error if there is one (which includes a location being in 
# Northern Ireland). The information in the query may be used by cobranded versions
# of the site to diambiguate locations.
sub lookup {
    my ($s, $q) = @_;
    my ($easting, $northing, $error);
    if ($s =~ /^\d+$/) {
        $error = 'FixMyStreet is a UK-based website that currently works in England, Scotland, and Wales. Please enter either a postcode, or a Great British street name and area.';
    } elsif (mySociety::PostcodeUtil::is_valid_postcode($s)) {
        my $location = mySociety::MaPit::call('postcode', $s);
        unless ($error = Page::mapit_check_error($location)) {
            $easting = $location->{easting};
            $northing = $location->{northing};
        }
    } else {
        ($easting, $northing, $error) = FixMyStreet::Geocode::string($s, $q);
    }
    return ($easting, $northing, $error);
}

sub geocoded_string_coordinates {
    my ($js, $q) = @_;
    my ($easting, $northing, $error);
    my ($accuracy) = $js =~ /"Accuracy" *: *(\d)/;
    if ($accuracy < 4) {  
        $error = _('Sorry, that location appears to be too general; please be more specific.');
    } else {

         $js =~ /"coordinates" *: *\[ *(.*?), *(.*?),/;
         my $lon = $1; my $lat = $2;
         try {
              ($easting, $northing) = mySociety::GeoUtil::wgs84_to_national_grid($lat, $lon, 'G');
          } catch Error::Simple with {
              $error = shift;
              $error = _('That location does not appear to be in Britain; please try again.')
                 if $error =~ /out of the area covered/;
          }
     }
    return ($easting, $northing, $error);
}

# string STRING QUERY
# Canonicalises, looks up on Google Maps API, and caches, a user-inputted location.
# Returns array of (TILE_X, TILE_Y, EASTING, NORTHING, ERROR), where ERROR is
# either undef, a string, or an array of matches if there are more than one. The 
# information in the query may be used to disambiguate the location in cobranded versions
# of the site. 
sub string {
    my ($s, $q) = @_;
    $s = lc($s);
    $s =~ s/[^-&0-9a-z ']/ /g;
    $s =~ s/\s+/ /g;
    $s = URI::Escape::uri_escape_utf8($s);
    $s = Cobrand::disambiguate_location(Page::get_cobrand($q), "q=$s", $q);
    $s =~ s/%20/+/g;
    my $url = 'http://maps.google.com/maps/geo?' . $s;
    my $cache_dir = mySociety::Config::get('GEO_CACHE');
    my $cache_file = $cache_dir . md5_hex($url);
    my ($js, $error, $easting, $northing);
    if (-s $cache_file) {
        $js = File::Slurp::read_file($cache_file);
    } else {
        $url .= ',+UK' unless $url =~ /united\++kingdom$/ || $url =~ /uk$/i;
        $url .= '&sensor=false&gl=uk&key=' . mySociety::Config::get('GOOGLE_MAPS_API_KEY');
        $js = LWP::Simple::get($url);
        File::Slurp::write_file($cache_file, $js) if $js && $js !~ /"code":6[12]0/;
    }
    if (!$js) {
        $error = _('Sorry, we could not parse that location. Please try again.');
    } elsif ($js !~ /"code" *: *200/) {
        $error = _('Sorry, we could not find that location.');
    } elsif ($js =~ /}, *{/) { # Multiple
        my @js = split /}, *{/, $js;
        my @valid_locations;
        foreach (@js) {
            next unless /"address" *: *"(.*?)"/s;
            my $address = $1;
            next unless Cobrand::geocoded_string_check(Page::get_cobrand($q), $address, $q);
            next if $address =~ /BT\d/;
            push (@valid_locations, $_); 
            push (@$error, $address);
        }
        if (scalar @valid_locations == 1) {
           return geocoded_string_coordinates($valid_locations[0], $q);
        }
        $error = _('Sorry, we could not find that location.') unless $error;
    } elsif ($js =~ /BT\d/) {
        # Northern Ireland, hopefully
        $error = _("We do not cover Northern Ireland, I'm afraid, as our licence doesn't include any maps for the region.");
    } else {
        ($easting, $northing, $error) = geocoded_string_coordinates($js, $q);
    }
    return ($easting, $northing, $error);
}

# list_choices
# Prints response if there's more than one possible result
sub list_choices {
    my ($choices, $page, $q) = @_;
    my $url;
    my $cobrand = Page::get_cobrand($q);
    my $message = _('We found more than one match for that location. We show up to ten matches, please try a different search if yours is not here.');
    my $out = '<p>' . $message . '</p>';
    my $choice_list = '<ul>';
    foreach my $choice (@$choices) {
        $choice =~ s/, United Kingdom//;
        $choice =~ s/, UK//;
        $url =  Cobrand::url($cobrand, NewURL($q, -retain => 1, -url => $page, 'pc' => $choice), $q);  
        $url =~ s/%20/+/g;
        $choice_list .= '<li><a href="' . $url . '">' . $choice . "</a></li>\n";
    }
    $choice_list .= '</ul>';
    $out .= $choice_list;
    my %vars = (message => $message, 
                choice_list => $choice_list, 
                header => _('More than one match'), 
                url_home => Cobrand::url($cobrand, '/', $q));
    my $cobrand_choice = Page::template_include('geocode-choice', $q, Page::template_root($q), %vars);
    return $cobrand_choice if $cobrand_choice;
    return $out;
}

1;
