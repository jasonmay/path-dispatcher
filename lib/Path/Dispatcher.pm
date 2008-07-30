#!/usr/bin/env perl
package Path::Dispatcher;
use Moose;
use MooseX::AttributeHelpers;

use Path::Dispatcher::Rule;

sub rule_class { 'Path::Dispatcher::Rule' }
sub stages { qw/before on after/ }

has _rules => (
    metaclass => 'Collection::Array',
    is        => 'rw',
    isa       => 'ArrayRef[Path::Dispatcher::Rule]',
    default   => sub { [] },
    provides  => {
        push     => '_add_rule',
        elements => 'rules',
    },
);

has super_dispatcher => (
    is        => 'rw',
    isa       => 'Path::Dispatcher',
    predicate => 'has_super_dispatcher',
);

sub add_rule {
    my $self = shift;

    my $rule;

    # they pass in an already instantiated rule..
    if (@_ == 1 && blessed($_[0])) {
        $rule = shift;
    }
    # or they pass in args to create a rule
    else {
        $rule = $self->rule_class->new(@_);
    }

    $self->_add_rule($rule);
}

sub dispatch {
    my $self = shift;
    my $path = shift;

    my @matches;
    my %rules_for_stage;

    push @{ $rules_for_stage{$_->stage} }, $_
        for $self->rules;

    for my $stage ($self->stages) {
        $self->begin_stage($stage, \@matches);
        my $stage_matches = 0;

        for my $rule (@{ $rules_for_stage{$stage} || [] }) {
            my $vars = $rule->match($path)
                or next;

            ++$stage_matches;

            push @matches, {
                rule   => $rule,
                result => $vars,
            };

            last if !$rule->fallthrough;
        }

        my $defer = $stage_matches == 0
                 && $self->has_super_dispatcher
                 && $self->defer_to_super_dispatcher($stage);

        if ($defer) {
            push @matches, $self->super_dispatcher->dispatch($path);
        }

        $self->end_stage($stage, \@matches);
    }

    return if !@matches;

    return $self->build_runner(
        path    => $path,
        matches => \@matches,
    );
}

sub build_runner {
    my $self = shift;
    my %args = @_;

    my $path    = $args{path};
    my $matches = $args{matches};

    return sub {
        eval {
            local $SIG{__DIE__} = 'DEFAULT';
            for my $match (@$matches) {
                if (ref($match) eq 'CODE') {
                    $match->();
                    next;
                }

                # if we need to set $1, $2..
                if (ref($match->{result}) eq 'ARRAY') {
                    $self->run_with_number_vars(
                        sub { $match->{rule}->run($path) },
                        @{ $match->{result} },
                    );
                }
                else {
                    $match->{rule}->run($path);
                }
            }
        };

        die $@ if $@ && $@ !~ /^Patch::Dispatcher abort\n/;
    };
}

sub run_with_number_vars {
    my $self = shift;
    my $code = shift;

    # we don't have direct write access to $1 and friends, so we have to
    # do this little hack. the only way we can update $1 is by matching
    # against a regex (5.10 fixes that)..
    my $re = join '', map { "(\Q$_\E)" } @_;
    my $str = join '', @_;
    $str =~ $re
        or die "Unable to match '$str' against a copy of itself!";

    $code->();
}

sub run {
    my $self = shift;
    my $code = $self->dispatch(@_);

    return $code->();
}

sub begin_stage {}
sub end_stage {}

sub defer_to_super_dispatcher {
    my $self = shift;
    my $stage = shift;

    return 1 if $stage eq 'on';
    return 0;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;

