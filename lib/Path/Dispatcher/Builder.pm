package Path::Dispatcher::Builder;
use Any::Moose;

our $OUTERMOST_DISPATCHER;
our $UNDER_RULE;

has dispatcher => (
    is          => 'ro',
    isa         => 'Path::Dispatcher',
    lazy        => 1,
    default     => sub { return Path::Dispatcher->new },
);

has case_sensitive_tokens => (
    is          => 'rw',
    isa         => 'Bool',
    default     => 1,
);

has token_delimiter => (
    is          => 'rw',
    isa         => 'Str',
    default     => ' ',
);

sub next_rule () {
    die "Path::Dispatcher next rule\n";
}

sub last_rule () {
    die "Path::Dispatcher abort\n";
}

sub dispatch {
    my $self = shift;

    local $OUTERMOST_DISPATCHER = $self->dispatcher
        if !$OUTERMOST_DISPATCHER;

    $OUTERMOST_DISPATCHER->dispatch(@_);
}

sub run {
    my $self = shift;

    local $OUTERMOST_DISPATCHER = $self->dispatcher
        if !$OUTERMOST_DISPATCHER;

    $OUTERMOST_DISPATCHER->run(@_);
}

sub rewrite {
    my $self = shift;
    my ($from, $to) = @_;
    my $rewrite = sub {
        local $OUTERMOST_DISPATCHER = $self->dispatcher
            if !$OUTERMOST_DISPATCHER;
        my $path = ref($to) eq 'CODE' ? $to->() : $to;
        $OUTERMOST_DISPATCHER->run($path, @_);
    };
    $self->_add_rule($from, $rewrite);
}

sub on {
    my $self = shift;
    $self->_add_rule(@_);
}

sub then {
    my $self = shift;
    my $block = shift;
    my $rule = Path::Dispatcher::Rule::Always->new(
        block => sub {
            $block->(@_);
            next_rule;
        },
    );
    $self->_add_rule($rule);
}

sub chain {
    my $self = shift;
    my $block = shift;
    my $rule = Path::Dispatcher::Rule::Chain->new(
        block => $block,
    );
    $self->_add_rule($rule);
}

sub under {
    my $self = shift;
    my ($matcher, $rules) = @_;

    my $predicate = $self->_create_rule($matcher);
    $predicate->prefix(1);

    my $under = Path::Dispatcher::Rule::Under->new(
        predicate => $predicate,
    );

    $self->_add_rule($under, @_);

    do {
        local $UNDER_RULE = $under;
        $rules->();
    };
}

sub redispatch_to {
    my $self = shift;
    my $dispatcher = shift;

    # assume it's a declarative dispatcher
    if (!ref($dispatcher)) {
        $dispatcher = $dispatcher->dispatcher;
    }

    my $redispatch = Path::Dispatcher::Rule::Dispatch->new(
        dispatcher => $dispatcher,
    );

    $self->_add_rule($redispatch);
}

sub rule_creators {
    return {
        ARRAY => sub {
            my ($self, $tokens, $block) = @_;

            Path::Dispatcher::Rule::Tokens->new(
                tokens => $tokens,
                delimiter => $self->token_delimiter,
                case_sensitive => $self->case_sensitive_tokens,
                $block ? (block => $block) : (),
            ),
        },
        HASH => sub {
            my ($self, $metadata_matchers, $block) = @_;

            if (keys %$metadata_matchers == 1) {
                my ($field) = keys %$metadata_matchers;
                my ($value) = values %$metadata_matchers;
                my $matcher = $self->_create_rule($value);

                return Path::Dispatcher::Rule::Metadata->new(
                    field   => $field,
                    matcher => $matcher,
                    $block ? (block => $block) : (),
                );
            }

            die "Doesn't support multiple metadata rules yet";
        },
        CODE => sub {
            my ($self, $matcher, $block) = @_;
            Path::Dispatcher::Rule::CodeRef->new(
                matcher => $matcher,
                $block ? (block => $block) : (),
            ),
        },
        Regexp => sub {
            my ($self, $regex, $block) = @_;
            Path::Dispatcher::Rule::Regex->new(
                regex => $regex,
                $block ? (block => $block) : (),
            ),
        },
        empty => sub {
            my ($self, $undef, $block) = @_;
            Path::Dispatcher::Rule::Empty->new(
                $block ? (block => $block) : (),
            ),
        },
    };
}

sub _create_rule {
    my ($self, $matcher, $block) = @_;

    my $rule_creator;

    if ($matcher eq '') {
        $rule_creator = $self->rule_creators->{empty};
    }
    elsif (!ref($matcher)) {
        $rule_creator = $self->rule_creators->{ARRAY};
        $matcher = [$matcher];
    }
    else {
        $rule_creator = $self->rule_creators->{ ref $matcher };
    }

    $rule_creator or die "I don't know how to create a rule for type $matcher";

    return $rule_creator->($self, $matcher, $block);
}

sub _add_rule {
    my $self = shift;
    my $rule;

    if (blessed($_[0]) && $_[0]->isa('Path::Dispatcher::Rule')) {
        $rule = shift;
    }
    else {
        my ($matcher, $block) = splice @_, 0, 2;
        $rule = $self->_create_rule($matcher, $block);
    }

    # FIXME: broken since move from ::Declarative
    # XXX: caller level should be closer to $Test::Builder::Level
#    my (undef, $file, $line) = caller(1);
    my (undef, $file, $line) = caller(2);
    my $rule_name = "$file:$line";

    if (!defined(wantarray)) {
        if ($UNDER_RULE) {
            $UNDER_RULE->add_rule($rule);

            my $full_name = $UNDER_RULE->has_name
                          ? "(" . $UNDER_RULE->name . " - rule $rule_name)"
                          : "(anonymous Under - rule $rule_name)";

            $rule->name($full_name) unless $rule->has_name;
        }
        else {
            $self->dispatcher->add_rule($rule);
            $rule->name("(" . $self->dispatcher->name . " - rule $rule_name)")
                unless $rule->has_name;
        }
    }
    else {
        $rule->name($rule_name)
            unless $rule->has_name;
        return $rule, @_;
    }
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

