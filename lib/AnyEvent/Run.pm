package AnyEvent::Run;
our $VERSION = '0.8.7';
use constant UNDEF => 'undefined';

use 5.16.1;
use strict;
use warnings;

use Ref::Util qw(is_refref is_coderef is_arrayref is_hashref);
use List::Util qw(first);
use Scalar::Util qw(blessed);
use AnyEvent;
use AnyEvent::Log;

use enum qw(:I_ CHAIN_CB AE_RUN RES ERR);

use Exporter qw(import);
our @EXPORT_OK = qw(ae_run_seq ae_run_conc is_valid_async_cb);

use Data::Dumper qw(Dumper);
use Carp qw(croak);

use subs qw(is_valid_async_cb __checked_cv __get_kv_opts __first_coderef_param);

sub ae_run_seq {
    state $dflt_on_error_cb = sub {
        AE::log warn => 'Possible error in async handler #%d: %s', 
                            $_[I_AE_RUN]->count, 
                            ref($_[I_ERR]) 
                              ? substr(Dumper($_[I_ERR]), 0, 1024) 
                              : $_[I_ERR] // UNDEF;
        undef
    };
    my %opts = &__get_kv_opts;
    my $cv = $opts{'dont_recv'} ? undef : ( __checked_cv($opts{'cv'}) // AE::cv );
    my ($before_each_cb, $on_exception_cb, $on_error_cb) = map is_valid_async_cb($_), @opts{qw/before_each on_exception on_error/};
    $on_error_cb //= $dflt_on_error_cb;
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
            
        (my $opts, $cb) =
            is_arrayref( $cb )
              ?  @{$cb}
              : ( {}, $cb );
              
        is_valid_async_cb( $cb )
            or croak 'all callbacks passed to ae_run_seq() must be code references';
        
        unshift @_, __SUB__, $ae_run;
        
        if ( is_coderef(my $repack_args_cb = $opts->{'repack'}) ) {
            &{$repack_args_cb}
        }
        
        $ae_run->count++;
        
        # Before Each ->
        $before_each_cb and &{$before_each_cb};
        # <- Before Each
        
        # On Handler Error ->
        defined $_[I_ERR]
            and
        (caller 0)[0] eq 'AnyEvent::HTTP' && is_hashref($_[I_ERR]) && exists($_[I_ERR]{'Status'})
          ? 
            ($_[I_ERR]{'Status'} =~ /^[23]/)
                || $on_error_cb->(
                        @_[0..I_AE_RUN],
                        sprintf('HTTP Status: %d, Reason: %s', @{$_[I_ERR]}{qw/Status Reason/})
                    )
          : &{$on_error_cb}
            and
        return
            $cv
              ? $cv->send(undef, $_[I_ERR])
              : 	 (undef, $_[I_ERR]);
        # <- On Handler Error
        
        # On Exception ->
        $on_exception_cb
            ? do {
                my $rv = eval { &{$cb} };
                $@ 
                    ? do { 
                        $on_exception_cb->(@_[0..I_RES], $@);
                        $cv
                            ? $cv->send(undef, sprintf 'Exception in %s handler #%d: %s', __PACKAGE__, $_[I_AE_RUN]->count, $_[I_ERR])
                            : undef
                      }
                    : $rv
              }
            : &{$cb}
        # <- On Exception
    }->( @pass_args );
    $cv and $cv->recv
}

sub ae_run_conc {
    my %opts = &__get_kv_opts;
    my $cv = __checked_cv($opts{'cv'}) // AE::cv;
    my $continue_cb = ( is_refref($_[$#_]) and is_coderef(${$_[$#_]}) ) ? ${pop @_} : undef;
    my $auto_end = sub { $cv->end };
    for my $callback ( @_ ) {
        $cv->begin;
        $callback->($cv, $auto_end);
    }
    $continue_cb and $continue_cb->($cv) or $opts{'dont_recv'} or $cv->recv;
}

sub is_valid_async_cb {
    ( defined($_[0]) and ( 
        is_coderef($_[0])
            or
        blessed($_[0]) and $_[0]->isa('AnyEvent::CondVar')
    ) and $_[0] ) or undef
}

sub __checked_cv {
    blessed($_[0]) && ref($_[0]) eq 'AnyEvent::CondVar' or return;
    $_[0]
}

sub __first_coderef_param {
    my $fcbi;
    defined($fcbi = first { is_valid_async_cb $_[$_ << 1] } 0 .. (($#_ + 1) >> 1))
      ? $fcbi << 1
      : undef
}

sub __get_kv_opts {
    my $i = &__first_coderef_param;
    defined $i 	or  die 'no callbacks provided';
    $i & 1	and die 'only key => value pairs acceptable before first coderef argument';
    my @kv_opts = $i ? splice(@_, 0, $i, ()) : ();
    wantarray ? @kv_opts : +{@kv_opts}
}

sub __std_final_cb {
    $_[0]->send
}

package AnyEvent::Run::Object;
use Class::XSAccessor::Array {
    accessors => {
        cv	=> 0,
        hold  	=> 1
    },
    lvalue_accessors => {
        count => 2
    },
    replace 	=> 1
};

sub new {
    my ($class, $cv, $hold) = @_;
    bless [
        $cv,
        $hold && ref($hold) eq 'HASH' ? $hold : {},
        my $count = 0
    ], ref($class) || $class
}

1;
