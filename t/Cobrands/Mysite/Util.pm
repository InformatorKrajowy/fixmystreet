#!/usr/bin/perl -w
#
# Util.pm:
# Test Cobranding for FixMyStreet.
#
#
# Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: louise@mysociety.org. WWW: http://www.mysociety.org
#
# $Id: Util.pm,v 1.20 2009-12-16 12:43:13 matthew Exp $

package Cobrands::Mysite::Util;
use Page;
use strict;
use Carp;
use mySociety::Web qw(ent);

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub site_name {
    return 'mysite';
}

sub site_restriction {
    return (' and council = 1 ', 99);
}

sub page {
    my %params = ();
    return ("A cobrand produced page", %params);
}

sub base_url {
    return 'http://mysite.example.com';
}

sub base_url_for_emails {
    return 'http://mysite.foremails.example.com';
}

sub disambiguate_location { 
    return 'Specific Location';
}

sub form_elements {
    return "Extra html";
}

sub extra_problem_data {
    return "Cobrand problem data";
}

sub extra_update_data {
    return "Cobrand update data";
}

sub extra_alert_data {
    return "Cobrand alert data";
}

sub extra_params {
    return 'key=value';
}

sub header_params {
    my %params = ('key' => 'value');
    return \%params;
}


sub root_path_js {
    return 'root path js';
}

sub site_title {
    return 'Mysite Title';
}

sub on_map_list_limit {
    return 30;
}

sub url { 
    return '/transformed_url';
}

sub allow_photo_upload {
    return 0;
}

sub allow_photo_display {
    return 0;
}

sub council_check { 
    return 0;
}

sub recent {
    return [
        { id => 1, title => 'Title 1' },
        { id => 2, title => 'Title 2' }
    ];
}

1;
