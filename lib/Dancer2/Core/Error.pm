# ABSTRACT: Class representing fatal errors

package Dancer2::Core::Error;
use Moo;
use Carp;
use Dancer2::Core::Types;
use Dancer2::Core::HTTP;
use Data::Dumper;
use Dancer2::FileUtils 'path';

=head1 SYNOPSIS

    # taken from send_file:
    use Dancer2::Core::Error;

    my $error = Dancer2::Core::Error->new(
        status    => 404,
        message => "No such file: `$path'"
    );

    Dancer2::Core::Response->set($error->render);

=head1 DESCRIPTION

With Dancer2::Core::Error you can throw reasonable-looking errors to the user
instead of crashing the application and filling up the logs.

This is usually used in debugging environments, and it's what Dancer2 uses as
well under debugging to catch errors and show them on screen.


=method my $error=new Dancer2::Core::Error(status    => 404, message => "No such file: `$path'");

Create a new Dancer2::Core::Error object. For available arguments see ATTRIBUTES.

=cut

=method supported_hooks ();

=cut

=attr show_errors

=cut

has show_errors => (
    is      => 'ro',
    isa     => Bool,
    default => sub {
        $_[0]->context->app->setting('show_errors') if $_[0]->has_context;
    },
);

=attr charset
=cut

has charset => (
    is      => 'ro',
    isa     => Str,
    default => sub {'UTF-8'},
);

=attr type

The error type.

=cut

has type => (
    is      => 'ro',
    isa     => Str,
    default => sub {'Runtime Error'},
);

=attr title

The title of the error page.

This is only an attribute getter, you'll have to set it at C<new>.

=cut

has title => (
    is      => 'rw',
    isa     => Str,
    lazy    => 1,
    builder => '_build_title',
);

sub _build_title {
    my ($self) = @_;
    my $title = 'Error ' . $self->status;
    if ( my $msg = Dancer2::Core::HTTP->status_message($self->status) ) {
        $title .= ' - ' . $msg;
    }

    return $title;
}

has template => (
    is => 'ro',

#    isa => sub { ref($_[0]) eq 'SCALAR' || ReadableFilePath->(@_) },
    lazy    => 1,
    builder => '_build_error_template',
);

sub _build_error_template {
    my ($self) = @_;

    # look for a template named after the status number.
    # E.g.: views/404.tt  for a TT template
    return $self->status
      if -f $self->context->app->engine('template')
          ->view_pathname( $self->status );

    return undef;
}

has static_page => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_static_page',
);

sub _build_static_page {
    my ($self) = @_;

    # TODO there must be a better way to get it
    my $public_dir = $ENV{DANCER_PUBLIC}
      || ( $self->has_context
        && path( $self->context->app->config_location, 'public' ) );

    my $filename = sprintf "%s/%d.html", $public_dir, $self->status;

    open my $fh, $filename or return undef;

    local $/ = undef;    # slurp time

    return <$fh>;
}


sub default_error_page {
    my $self = shift;

    require Template::Tiny;

    my $opts = {
        title   => $self->title,
        charset => $self->charset,
        content => $self->message,
        version => Dancer2->VERSION,
    };

    Template::Tiny->new->process( \<<"END_TEMPLATE", $opts, \my $output );
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html>
<head>
<title>[% title %]</title>
<link rel="stylesheet" href="/css/error.css" />
<meta http-equiv="Content-type" content="text/html; charset='[% charset %]'" />
</head>
<body>
<h1>[% title %]</h1>
<div id="content">
[% content %]
</div>
<div id="footer">
Powered by <a href="http://perldancer.org/">Dancer2</a> [% version %]
</div>
</body>
</html>
END_TEMPLATE

    return $output;
}


=attr status

The status that caused the error.

This is only an attribute getter, you'll have to set it at C<new>.

=cut

has status => (
    is      => 'ro',
    default => sub {500},
    isa     => Num,
);

=attr message

The message of the error page.

=cut

has message => (
    is  => 'rw',
    isa => Str,
);

sub full_message {
    my ($self) = @_;
    my $html_output = "<h2>" . $self->type . "</h2>";
    $html_output .= $self->backtrace;
    $html_output .= $self->environment;
    return $html_output;
}

has serializer => (
    is  => 'ro',
    isa => ConsumerOf ['Dancer2::Core::Role::Serializer'],
);

has session => (
    is  => 'ro',
    isa => ConsumerOf ['Dancer2::Core::Role::Session'],
);

has context => (
    is        => 'ro',
    isa       => InstanceOf ['Dancer2::Core::Context'],
    predicate => 1,
);

sub BUILD {
    my ($self) = @_;
    $self->has_context &&
        $self->context->app->execute_hook( 'core.error.init', $self );
}

has exception => (
    is  => 'rw',
    isa => Str,
);

has response => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        $_[0]->has_context
          ? $_[0]->context->response
          : Dancer2::Core::Response->new;
    },
);

has content_type => (
    is      => 'ro',
    default => sub {'text/html'},
);

has content => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;

        # we check for a template, for a static file and,
        # if all else fail, the default error page

        if ( $self->has_context and $self->template ) {
            return $self->context->app->template(
                $self->template,
                {   title   => $self->title,
                    content => $self->message,
                    status  => $self->status,
                }
            );
        }

        if ( my $content = $self->static_page ) {
            return $content;
        }

        return $self->default_error_page;
    },
);

=method throw($response)

Populates the content of the response with the error's information.
If I<$response> is not given, acts on the I<context> 
attribute's response.

=cut

sub throw {
    my $self = shift;
    $self->response(shift) if @_;

    croak "error has no response to throw at" unless $self->response;

    $self->has_context &&
        $self->context->app->execute_hook( 'core.error.before', $self );

    my $message = $self->content;
    $message .= "\n\n" . $self->exception
      if $self->show_errors && defined $self->exception;

    $self->response->status( $self->status );
    $self->response->header( $self->content_type );
    $self->response->content($message);

    $self->has_context &&
        $self->context->app->execute_hook('core.error.after', $self->response);

    $self->response->halt(1);
    return $self->response;
}

=method backtrace

Create a backtrace of the code where the error is caused.

This method tries to find out where the error appeared according to the actual
error message (using the C<message> attribute) and tries to parse it (supporting
the regular/default Perl warning or error pattern and the L<Devel::SimpleTrace>
output) and then returns an error-higlighted C<message>.

=cut

sub backtrace {
    my ($self) = @_;

    my $message =
      qq|<pre class="error">| . _html_encode( $self->message ) . "</pre>";

    # the default perl warning/error pattern
    my ( $file, $line ) = ( $message =~ /at (\S+) line (\d+)/ );

    # the Devel::SimpleTrace pattern
    ( $file, $line ) = ( $message =~ /at.*\((\S+):(\d+)\)/ )
      unless $file and $line;

    # no file/line found, cannot open a file for context
    return $message unless ( $file and $line );

    # file and line are located, let's read the source Luke!
    my $fh = open_file( '<', $file ) or return $message;
    my @lines = <$fh>;
    close $fh;

    my $backtrace = $message;

    $backtrace
      .= qq|<div class="title">| . "$file around line $line" . "</div>";

    $backtrace .= qq|<pre class="content">|;

    $line--;
    my $start = ( ( $line - 3 ) >= 0 ) ? ( $line - 3 ) : 0;
    my $stop =
      ( ( $line + 3 ) < scalar(@lines) ) ? ( $line + 3 ) : scalar(@lines);

    for ( my $l = $start; $l <= $stop; $l++ ) {
        chomp $lines[$l];

        if ( $l == $line ) {
            $backtrace
              .= qq|<span class="nu">|
              . tabulate( $l + 1, $stop + 1 )
              . qq|</span> <span style="color: red;">|
              . _html_encode( $lines[$l] )
              . "</span>\n";
        }
        else {
            $backtrace
              .= qq|<span class="nu">|
              . tabulate( $l + 1, $stop + 1 )
              . "</span> "
              . _html_encode( $lines[$l] ) . "\n";
        }
    }
    $backtrace .= "</pre>";


    return $backtrace;
}


=method tabulate

Small subroutine to help output nicer.

=cut 

sub tabulate {
    my ( $number, $max ) = @_;
    my $len = length($max);
    return $number if length($number) == $len;
    return " $number";
}

=head2 dumper

This uses L<Data::Dumper> to create nice content output with a few predefined
options.

=cut

sub dumper {
    my $obj = shift;

    # Take a copy of the data, so we can mask sensitive-looking stuff:
    my %data     = %$obj;
    my $censored = _censor( \%data );

    #use Data::Dumper;
    my $dd = Data::Dumper->new( [ \%data ] );
    $dd->Terse(1)->Quotekeys(0)->Indent(1);
    my $content = $dd->Dump();
    $content =~ s{(\s*)(\S+)(\s*)=>}{$1<span class="key">$2</span>$3 =&gt;}g;
    if ($censored) {
        $content
          .= "\n\nNote: Values of $censored sensitive-looking keys hidden\n";
    }
    return $content;
}


=method environment

A main function to render environment information: the caller (using
C<get_caller>), the settings and environment (using C<dumper>) and more.

=cut

sub environment {
    my ($self) = @_;

    my $request = $self->has_context ? $self->context->request : 'TODO';
    my $r_env = {};
    $r_env = $request->env if defined $request;

    my $env =
        qq|<div class="title">Environment</div><pre class="content">|
      . dumper($r_env)
      . "</pre>";
    my $settings =
        qq|<div class="title">Settings</div><pre class="content">|
      . dumper( $self->app->settings )
      . "</pre>";
    my $source =
        qq|<div class="title">Stack</div><pre class="content">|
      . $self->get_caller
      . "</pre>";
    my $session = "";

    if ( $self->session ) {
        $session =
            qq[<div class="title">Session</div><pre class="content">]
          . dumper( $self->session->data )
          . "</pre>";
    }
    return "$source $settings $session $env";
}


=method get_caller

Creates a strack trace of callers.

=cut

sub get_caller {
    my ($self) = @_;
    my @stack;

    my $deepness = 0;
    while ( my ( $package, $file, $line ) = caller( $deepness++ ) ) {
        push @stack, "$package in $file l. $line";
    }

    return join( "\n", reverse(@stack) );
}

# private

# Given a hashref, censor anything that looks sensitive.  Returns number of
# items which were "censored".

=func _censor

An private function that tries to censor out content which should be protected.

C<dumper> calls this method to censor things like passwords and such.

=cut 

sub _censor {
    my $hash = shift;
    if ( !$hash || ref $hash ne 'HASH' ) {
        carp "_censor given incorrect input: $hash";
        return;
    }

    my $censored = 0;
    for my $key ( keys %$hash ) {
        if ( ref $hash->{$key} eq 'HASH' ) {
            $censored += _censor( $hash->{$key} );
        }
        elsif ( $key =~ /(pass|card?num|pan|secret)/i ) {
            $hash->{$key} = "Hidden (looks potentially sensitive)";
            $censored++;
        }
    }

    return $censored;
}

=func my $string=_html_encode ($string);

Private function that replaces illegal entities in (X)HTML with their
escaped representations. 

html_encode() doesn't do any UTF black magic.

=cut

# Replaces the entities that are illegal in (X)HTML.
sub _html_encode {
    my $value = shift;

    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/'/&#39;/g;
    $value =~ s/"/&quot;/g;

    return $value;
}

sub _render_html {
    my $self = shift;

    # error_template defaults to something, always
    my $template_name = $self->error_template;

    my $ops = {
        title   => $self->title,
        content => $self->message,
        status  => $self->status,
        defined $self->exception ? ( exception => $self->exception ) : (),
    };
    my $content = $self->template->apply_renderer( $template_name, $ops );
    $self->response->status( $self->status );
    $self->response->header( 'Content-Type' => 'text/html' );
    return $content;
}

1;

