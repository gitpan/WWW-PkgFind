=head1 NAME

WWW::PkgFind -  Spiders given URL(s) downloading wanted files

=head1 SYNOPSIS

my $Pkg = new WWW::PkgFind("foobar");
$Pkg->depth(3);
$Pkg->active_urls("ftp://ftp.somesite.com/pub/joe/foobar/");
$Pkg->wanted_regex("patch-2\.6\..*gz", "linux-2\.6.\d+\.tar\.bz2");
$Pkg->set_create_queue("/testing/packages/QUEUE");
$Pkg->retrieve();

=head1 DESCRIPTION

TODO

=head1 FUNCTIONS

=cut

package WWW::PkgFind;

use strict;
use warnings;
use Pod::Usage;
use Getopt::Long;
use LWP::Simple;
use WWW::RobotRules;
use File::Spec::Functions;
use File::Path;

use fields qw(
              _debug
              package_name
              depth
              wanted_regex
              not_wanted_regex
              rename_regexp
              active_urls
              robot_urls
              files
              processed
              create_queue
              rules
              user_agent
              );

use vars qw( %FIELDS $VERSION );
$VERSION = '1.00';

=head2 new([$pkg_name], [$agent_desc])

Creates a new WWW::PkgFind object

=cut
sub new {
    my $this = shift;
    my $class = ref($this) || $this;
    my $self = bless [\%FIELDS], $class;

    my $host = `hostname` || "nameless"; chomp $host;

    $self->{package_name}     = shift || 'unnamed_package';
    $self->{depth}            = 5;
    $self->{wanted_regex}     = [ ];
    $self->{not_wanted_regex} = [ ];
    $self->{rename_regexp}    = '';
    $self->{active_urls}      = [ ];
    $self->{robot_urls}       = { };
    $self->{files}            = [ ];
    $self->{processed}        = undef;
    $self->{create_queue}     = undef;
    $self->{rules}            = WWW::RobotRules->new(__PACKAGE__."/$VERSION");
    my $agent_desc = shift || '';
    $self->{user_agent}       = __PACKAGE__."/$VERSION $host spider $agent_desc";

    $self->{_debug}           = 0;

    return $self;
}

########################################################################
# Accessors                                                            #
########################################################################

=head2 package_name()

Gets/sets the package name

=cut
sub package_name {
    my $self = shift;
    if (@_) {
        $self->{package_name} = shift;
    }
    return $self->{package_name};
}

=head2 depth()

=cut
sub depth {
    my $self = shift;
    if (@_) {
        $self->{depth} = shift;
    }
    return $self->{depth};
}

=head2 wanted_regex()

=cut
sub wanted_regex {
    my $self = shift;

    foreach my $regex (@_) {
        next unless $regex;
        push @{$self->{wanted_regex}}, $regex;
    }
    return @{$self->{wanted_regex}};
}

=head2 not_wanted_regex()

=cut
sub not_wanted_regex {
    my $self = shift;

    foreach my $regex (@_) {
        next unless $regex;
        push @{$self->{not_wanted_regex}}, $regex;
    }
    return @{$self->{not_wanted_regex}};
}

=head2 rename_regex()

=cut
sub rename_regex {
    my $self = shift;

    if (@_) {
        $self->{rename_regex} = shift;
    }
    return $self->{rename_regex};
}

=head2 active_urls()

=cut
sub active_urls {
    my $self = shift;

    foreach my $url (@_) {
        next unless $url;
        push @{$self->{active_urls}}, [$url, $self->{depth}];
    }
    return @{$self->{active_urls}};
}

=head2 robot_urls()

=cut
sub robot_urls {
    my $self = shift;

    foreach my $url (@_) {
        next unless $url;
        $self->{robot_urls}->{$url} = 1;
    }
    return keys %{$self->{robot_urls}};
}

=head2 files()

=cut
sub files {
    my $self = shift;

    foreach my $file (@_) {
        next unless $file;
        push @{$self->{files}}, $file;
    }
    return @{$self->{files}};
}

=head2 processed()

=cut
sub processed {
    my $self = shift;
    return $self->{processed};
}

=head2 set_create_queue($dir)

Specifies that the retrieve() routine should also create a symlink queue 
in the specified directory.

=cut
sub set_create_queue {
    my $self = shift;

    if (@_) {
        $self->{create_queue} = shift;
    }

    return $self->{create_queue};
}

=head2 set_debug($debug)

Turns on debug level.  Set to 0 or undef to turn off.

=cut
sub set_debug {
    my $self = shift;

    if (@_) {
        $self->{_debug} = shift;
    }

    return $self->{_debug};
}

########################################################################
# Helper functions                                                     #
########################################################################

=head3 want_file($file)

Checks the regular expressions in the Pkg hash.
Returns 1 (true) if file matches at least one wanted regexp
and none of the not_wanted regexp's.  If the file matches a
not-wanted regexp, it returns 0 (false).  If it has no clue what
the file is, it returns undef (false).

=cut
sub want_file {
    my $self = shift;
    my $file = shift;

    warn "Considering '$file'...\n" if $self->{_debug}>3;
    foreach my $pattern ( @{$self->{'not_wanted_regex'}} ) {
        warn "Checking against not wanted pattern '$pattern'\n" if $self->{_debug}>3;
        if ($file =~ m/$pattern/) {
            warn "no\n" if $self->{_debug}>3;
            return 0;
        }
    }
    foreach my $pattern ( @{$self->{'wanted_regex'}} ) {
        warn "Checking against wanted pattern '$pattern'\n" if $self->{_debug}>3;
        if ($file =~ m/$pattern/) {
            warn "yes\n" if $self->{_debug}>3;
            return 1;
        }
    }
    warn "maybe\n" if $self->{_debug}>3;
    return undef;
}

=head2 get_file($url, $dest)

Retrieves the given URL, returning true if the file was
successfully obtained and placed at $dest, false if something
prevented this from happening.

get_file also checks for and respects robot rules, updating the
$rules object as needed, and caching url's it's checked in
%robot_urls.  $robot_urls{$url} will be >0 if a robots.txt was
found and parsed, <0 if no robots.txt was found, and
undef if the url has not yet been checked.

=cut
sub get_file {
    my $self = shift;
    my $url = shift  || return undef;
    my $dest = shift || return undef;

    my $uri = URI->new($url);
    if (! defined $self->{robot_urls}->{$uri->host()}) {
        my $robot_url = $uri->host() . "/robots.txt";
        my $robot_txt = get $robot_url;
        if (defined $robot_txt) {
            $self->{rules}->parse($url, $robot_txt);
            $self->{robot_urls}->{$uri->host()} = 1;
        } else {
            warn "ROBOTS:  Could not find '$robot_url'\n";
            $self->{robot_urls}->{$uri->host()} = -1;
        }
    }

    if (! $self->{rules}->allowed($url) ) {
        warn "ROBOTS:  robots.txt denies access to '$url'\n";
        return 0;
    }

    my $incoming = "${dest}.incoming";
    system("/usr/bin/curl",
           "--user-agent","'$self->{user_agent}'",
           "-Lo","$incoming",$url);
    my $retval = $?;
    if ($retval != 0) {
        warn "CURL ERROR($retval)\n";
        unlink($incoming);
        return 0;
    }

    if (! rename($incoming, $dest)) {
        warn "RENAME FAILED:  '$incoming' -> '$dest'\n";
        return 0;
    }

    return 1;
}


=head2

=cut
sub _process_active_urls {
    my $self = shift;

    warn "In WWW::PkgFind::_process_active_urls()\n" if $self->{_debug}>4;

    while ($self->{'active_urls'} && @{$self->{'active_urls'}}) {
        my $u_d = pop @{$self->{'active_urls'}};

        if (! $u_d) {
            warn "Undefined url/depth.  Skipping\n" if $self->{_debug}>0;
            next;
        }
        my ($url, $depth) = @{$u_d};
        if (! defined $depth) {
            $depth = 1;
            warn "Current depth undefined... assuming $depth\n" if $self->{_debug}>0;
        }

        next if ( $depth > $self->{'depth'});

        # Get content of this page
        warn "# Getting webpage $url\n" if $self->{_debug}>0;
        my $content = get($url);
        if (! $content) {
            warn "No content retrieved for '$url'\n" if $self->{_debug}>0;
            next;
        }

        # Grep for files
        my @lines = split /\<\s*A\s/si, $content;
        foreach my $line (@lines) {
            next unless ($line && $line =~ /HREF\s*\=\s*(\'|\")/si);
            my ($quote, $match) = $line =~ m/HREF\s*\=\s*(\'|\")(.*?)(\'|\")/si;
            my $new_url = $url;
            $new_url =~ s|/$||;

            $self->_process_line($match, $new_url, $depth);
        }
    }
}

# _process_line($match, $new_url, $depth)
# Processes one line, extracting files to be retrieved
sub _process_line {
    my $self    = shift;
    my $match   = shift or return undef;
    my $new_url = shift;
    my $depth   = shift || 1;

    warn "In WWW::PkgFind::_process_line()\n" if $self->{_debug}>4;

    my $is_wanted = $self->want_file($match);
    if ( $is_wanted ) {
        warn "FOUND FILE '$match'\n" if $self->{_debug}>1;
#        push @{$self->{'files'}}, "$new_url/$match";
        push @{$self->{'files'}}, "$match";

    } elsif (! defined $is_wanted) {
        return if ($depth == $self->{'depth'});
        if ( $match && $match ne '/' && $match !~ /^\?/) {
            # Is this a directory?
            return if ( $match =~ /\.\./);
            return if ( $match =~ /sign$/ );
            return if ( $match =~ /gz$/ );
            return if ( $match =~ /bz2$/ );
            return if ( $match =~ /dif$/ );
            return if ( $match =~ /patch$/ );

            if ($new_url =~ m/htm$|html$/) {
                # Back out of index.htm[l] type files
                $new_url .= '/..';
            }

            my $new_depth = $depth + 1;
            if ($match =~ m|^/|) {
                # Handle absolute links
                my $uri = URI->new($new_url);
                my $path = $uri->path();
                my @orig_path = $uri->path();
                
                # Link points somewhere outside our tree... skip it
                return if ($match !~ m|^$path|);
                
                # Construct new url for $match
                $new_url = $uri->scheme() . '://'
                    . $uri->authority()
                    . $match;
                $uri = URI->new($new_url);
                
                # Account for a link that goes deeper than 1 level
                # into the file tree, e.g. '$url/x/y/z/foo.txt'
                my @new_path = $uri->path();
                my $path_size = @new_path-@orig_path;
                if ($path_size < 1) {
                    $path_size = 1;
                }
                $new_depth = $depth + $path_size;

            } else {
                # For relative links, simply append to current
                $new_url .= "/$match";
            }

            warn "FOUND SUBDIR(?) '$new_url'\n" if $self->{_debug}>1;
            push @{$self->{'active_urls'}}, [ $new_url, $new_depth ];
        }

    } elsif ($is_wanted == 0) {
        warn "NOT WANTED: '$match'\n" if $self->{_debug}>1;
    }
}


=head2 retrieve()

=cut
sub retrieve {
    my $self = shift;
    my $destination = shift;

    warn "In WWW::PkgFind::retrieve()\n" if $self->{_debug}>4;

    if (! $destination ) {
        warn "No destination specified to WWW::PkgFind::retrieve()\n";
        return undef;
    }

    # If no wanted regexp's have been specified, we want everything
    if (! defined $self->{'wanted_regex'}->[0] ) {
        warn "No regexp's specified; retrieving everything.\n" if $self->{_debug}>2;
        push @{$self->{'wanted_regex'}}, '.*';
    }

    # Retrieve the listing of available files
    warn "Processing active urls\n" if $self->{_debug}>2;
    $self->_process_active_urls();

    if (! $self->{'package_name'}) {
        warn "Error:  No package name defined\n";
        return undef;
    }

    my $dest_dir = catdir($destination, $self->{'package_name'});
    if (! -d $dest_dir) {
        eval { mkpath([$dest_dir], 0, 0777); };
        if ($@) {
            warn "Error:  Couldn't create '$dest_dir': $@\n";
            return undef;
        }
    }

    # Download wanted files
    foreach my $wanted_url (@{$self->{'files'}}) {
        my @parts = split(/\//, $wanted_url);
        my $filename = pop @parts;
        my $dest = "$dest_dir/$filename";

        warn "Considering file '$filename'\n" if $self->{_debug}>2;

        if (! $filename) {
            warn "NOT FILENAME:  '$wanted_url'\n";
        } elsif (-f $dest) {
            warn "EXISTS:  '$dest'\n" if $self->{_debug}>0;
        } else {
            warn "NEW '$wanted_url'\n" if $self->{_debug}>0;

            if (! $self->get_file($wanted_url, $dest)) {
                warn "FAILED RETRIEVING $wanted_url.  Skipping.\n";
            } else {
                warn "RETRIEVED $dest\n";

                if (defined $self->{create_queue}) {
                    # Create a symlink queue
                    symlink("$dest", "$self->{create_queue}/$filename")
                        or warn("Could not create symbolic link $self->{create_queue}/$filename: $!\n");
                }
            }
        }
    }

    return $self->{processed} = 1;
}

=head1 AUTHOR

Bryce Harrington <bryce@osdl.org>

=head1 COPYRIGHT

Copyright (C) 2006 Bryce Harrington.
All Rights Reserved.

This script is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<perl>

=cut


1;
