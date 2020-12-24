package AnyEvent::Run;
use 5.16.1;
use strict;
use warnings;

use Ref::Util qw(is_refref is_coderef);
use List::Util qw(first);
use Scalar::Util qw(blessed);
use AnyEvent;

use Exporter qw(import);
our @EXPORT_OK = qw(ae_run_seq ae_run_conc);

use Data::Dumper;
use Carp qw(croak);

use subs qw(__checked_cv __first_coderef_param);

sub ae_run_seq {
    my %opts = do {
        my $i = &__first_coderef_param;
        defined $i 	or  die 'no callbacks provided';
        $i & 1		and die 'only key => value pairs acceptable before first coderef argument';
        $i ? splice(@_, 0, $i, ()) : ()
    };
    my $cv = $opts{'dont_recv'} ? undef : ( __checked_cv($opts{'cv'}) // AE::cv );
    my $ae_run = AnyEvent::Run::Object->new($cv, $opts{'hold'});
    my @pass_args = do {
        if ( exists $opts{'pass_args'} ) {
            my $pa = $opts{'pass_args'};
            ref($pa)
            ? ref($pa) eq 'ARRAY'
              ? @{$pa}
              : ref($pa) eq 'REF'
                ? ( ${$pa} ) # useful to pass something like \[qw/foo bar baz/] instead of [[qw/foo bar baz/]]
                : ( $pa )
            : ( $pa )
        } else {
            ()
        }
    };
    my @callbacks = @_ or croak 'no callbacks provided for chaining';
    sub { 
        defined( my $cb = shift @callbacks )
            or return( $opts{'dont_recv'} ? @_ : $cv->send(@_) );
        is_coderef($cb) or croak 'all callbacks passed to ae_run_seq() must be code references';
        unshift @_, __SUB__, $ae_run;
        &{$cb}
    }->( @pass_args );
    $cv and $cv->recv
}

sub ae_run_conc {
    my %opts = do {
        my $i = &__first_coderef_param;
        defined $i 	or  die 'no callbacks provided';
        $i & 1		and die 'only key => value pairs acceptable before first coderef argument';
        $i ? splice(@_, 0, $i, ()) : ()
    };
    my $cv = __checked_cv($opts{'cv'}) // AE::cv;
    
    my $continue_cb = ( is_refref($_[$#_]) and is_coderef(${$_[$#_]}) ) ? ${pop @_} : undef;
    my $auto_end = sub { $cv->end };
    for my $callback ( @_ ) {
        $cv->begin;
        $callback->($cv, $auto_end);
    }
    $continue_cb and $continue_cb->($cv) or $opts{'dont_recv'} or $cv->recv;
}

sub __checked_cv {
    blessed($_[0]) && ref($_[0]) eq 'AnyEvent::CondVar' or return;
    $_[0]
}

sub __first_coderef_param {
    my $i = first { is_coderef($_[$_]) } 0 .. $#_;
}

sub __std_final_cb {
    $_[0]->send
}

package AnyEvent::Run::Object;
use Class::XSAccessor::Array {
    accessors => {
        cv	=> 0,
        hold  	=> 1,
    },
    replace 	=> 1
};

sub new {
    my ($class, $cv, $hold) = @_;
    bless [
        $cv,
        $hold && ref($hold) eq 'HASH' ? $hold : {}
    ], ref($class) || $class
}

1;