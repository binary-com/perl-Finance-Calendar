package Finance::Calendar;

=head1 NAME

Finance::Calendar - represents the trading calendar.

=head1 SYNOPSIS

    use Finance::Calendar;
    use Date::Utility;

    my $calendar = {
        holidays => {
            "25-Dec-2013" => {
                "Christmas Day" => [qw(FOREX METAL)],
            },
            "1-Jan-2014" => {
                "New Year's Day" => [qw( FOREX METAL)],
            },
            "1-Apr-2013" => {
                "Easter Monday" => [qw( USD)],
            },
        },
        early_closes => {
            '24-Dec-2009' => {
                '16:30' => ['HKSE'],
            },
            '22-Dec-2016' => {
                '18:00' => ['FOREX', 'METAL'],
            },
        },
        late_opens => {
            '24-Dec-2010' => {
                '14:30' => ['HKSE'],
            },
        },
    };
    my $calendar = Finance::Calendar->new(calendar => $calendar);
    my $now = Date::Utility->new;

    # Does London Stocks Exchange trade on $now
    $calendar->trades_on(Finance::Exchange->create_exchange('LSE'), $now);

    # Is it a country holiday for the United States on $now
    $calendar->is_holiday_for('USD', $now);

    # Returns the opening time of Australian Stocks Exchange on $now
    $calendar->opening_on(Finance::Exchange->create_exchange('ASX'), $now);

    # Returns the closing time of Forex on $now
    $calendar->closing_on(Finance::Exchange->create_exchange('FOREX'), $now);
    ...

=head1 DESCRIPTION

This class is responsible for providing trading times or holidays related information of a given financial stock exchange on a specific date.

=cut

use Moose;

our $VERSION = 0.01;

use List::Util qw(min max first);
use Date::Utility;
use Memoize;
use Finance::Exchange;
use Carp qw(croak);

=head1 ATTRIBUTES - Object Construction

=head2 calendar

A hash reference that has information on:
- exchange and country holidays
- late opens
- early closes

=cut

has calendar => (
    is       => 'ro',
    required => 1,
);

=head1 METHODS - TRADING DAYS RELATED

=head2 trades_on

->trades_on($exchange_object, $date_object);

Returns true if trading is done on the day of a given Date::Utility.

=cut

sub trades_on {
    my ($self, $exchange, $when) = @_;

    my $really_when = $self->trading_date_for($exchange, $when);
    my $result = (@{$exchange->trading_days_list}[$really_when->day_of_week] && !$self->is_holiday_for($exchange->symbol, $really_when)) ? 1 : 0;

    return $result;
}

=head2 trade_date_before

->trade_date_before($exchange_object, $date_object);

Returns a Date::Utility object for the previous trading day of an exchange for the given date.

=cut

sub trade_date_before {
    my ($self, $exchange, $when) = @_;

    my $begin = $self->trading_date_for($exchange, $when);
    my $date_behind;
    my $counter = 1;

    # look back at most 7 days. The previous trading day could have span over a weekend with multiple consecutive holidays.
    while (not $date_behind and $counter < 7) {
        my $possible = $begin->minus_time_interval($counter . 'd');
        $date_behind = $possible if $self->trades_on($exchange, $possible);
        $counter++;
    }

    return $date_behind;
}

=head2 trade_date_after

->trade_date_after($exchange_object, $date_object);

Returns a Date::Utility object of the next trading day of an exchange for a given date.

=cut

sub trade_date_after {
    my ($self, $exchange, $date) = @_;

    my $date_next;
    my $counter = 1;
    my $begin = $self->trading_date_for($exchange, $date);

    # look forward at most 7 days. The next trading day could have span over a weekend with multiple consecutive holidays.
    while (not $date_next and $counter <= 7) {
        my $possible = $begin->plus_time_interval($counter . 'd');
        $date_next = $possible if $self->trades_on($exchange, $possible);
        $counter++;
    }

    return $date_next;
}

=head2 trading_date_for

->trading_date_for($exchange_object, $date_object);

The date on which trading is considered to be taking place even if it is not the same as the GMT date.
Note that this does not handle trading dates are offset forward beyond the next day (24h). It will need additional work if these are found to exist.

Returns a Date object representing midnight GMT of the trading date.

=cut

sub trading_date_for {
    my ($self, $exchange, $date) = @_;

    # if there's no pre-midnight open, then returns the same day.
    return $date->truncate_to_day unless ($exchange->trading_date_can_differ);

    my $next_day = $date->plus_time_interval('1d')->truncate_to_day;
    my $open_ti =
        $exchange->market_times->{$self->_times_dst_key($exchange, $next_day)}->{daily_open};

    return $next_day if ($open_ti and $next_day->epoch + $open_ti->seconds <= $date->epoch);
    return $date->truncate_to_day;
}

=head2 calendar_days_to_trade_date_after

->calendar_days_to_trade_date_after($exchange_object, $date_object);

Returns the number of calendar days between a given Date::Utility
and the next day on which trading is open.

=cut

sub calendar_days_to_trade_date_after {
    my ($self, $exchange, $when) = @_;

    return $self->trade_date_after($exchange, $when)->days_between($when);
}

Memoize::memoize('calendar_days_to_trade_date_after', NORMALIZER => '_normalize_on_dates');

=head2 trading_days_between


->trading_days_between($exchange_object, Date::Utility->new('4-May-10'),Date::Utility->new('5-May-10'));

Returns the number of trading days _between_ two given dates.

=cut

sub trading_days_between {
    my ($self, $exchange, $begin, $end) = @_;

    # Count up how many are trading days.
    return scalar grep { $self->trades_on($exchange, $_) } @{$self->_days_between($begin, $end)};
}

Memoize::memoize('trading_days_between', NORMALIZER => '_normalize_on_dates');

=head2 holiday_days_between

->holiday_days_between($exchange_object, Date::Utility->new('4-May-10'),Date::Utility->new('5-May-10'));

Returns the number of holidays _between_ two given dates.

=cut

sub holiday_days_between {
    my ($self, $exchange, $begin, $end) = @_;

    # Count up how many are trading days.
    return scalar grep { $self->is_holiday_for($exchange->symbol, $_) } @{$self->_days_between($begin, $end)};
}

Memoize::memoize('holiday_days_between', NORMALIZER => '_normalize_on_dates');

=head1 METHODS - TRADING TIMES RELATED.

=head2 is_open

->is_open($exchange_object);

Returns true is exchange is open now, false otherwise.

=cut

sub is_open {
    my ($self, $exchange) = @_;

    return $self->is_open_at($exchange, Date::Utility->new);
}

=head2 is_open_at

->is_open_at($exchange_object, $epoch);

Return true is exchange is open at the given epoch, false otherwise.

=cut

sub is_open_at {
    my ($self, $exchange, $date) = @_;

    my $opening = $self->opening_on($exchange, $date);

    return unless $opening;
    return if $self->_is_in_trading_break($exchange, $date);
    return 1 if (not $date->is_before($opening) and not $date->is_after($self->closing_on($exchange, $date)));
    # if everything falls through, assume it is not open
    return;
}

=head2 seconds_since_open_at

->seconds_since_open_at($exchange_object, $epoch);

Returns the number of seconds since the exchange opened from the given epoch.

=cut

sub seconds_since_open_at {
    my ($self, $exchange, $date) = @_;

    return $self->_market_opens($exchange, $date)->{'opened'};
}

=head2 seconds_since_close_at

->seconds_since_close_at($exchange_object, $epoch);

Returns the number of seconds since the exchange closed from the given epoch.

=cut

sub seconds_since_close_at {
    my ($self, $exchange, $date) = @_;

    return $self->_market_opens($exchange, $date)->{'closed'};
}

=head2 opening_on

->opening_on($exchange_object, Date::Utility->new('25-Dec-10')); # returns undef (given Xmas is a holiday)

Returns the opening time (Date::Utility) of the exchange for a given Date::Utility, undefined otherwise.

=cut

sub opening_on {
    my ($self, $exchange, $when) = @_;

    return $self->opens_late_on($exchange, $when) // $self->get_exchange_open_times($exchange, $when, 'daily_open');
}

=head2 closing_on

->closing_on($exchange_object, Date::Utility->new('25-Dec-10')); # returns undef (given Xmas is a holiday)

Returns the closing time (Date::Utility) of the exchange for a given Date::Utility, undefined otherwise.

=cut

sub closing_on {
    my ($self, $exchange, $when) = @_;

    return $self->closes_early_on($exchange, $when) // $self->get_exchange_open_times($exchange, $when, 'daily_close');
}

=head2 trading_breaks

->trading_breaks($exchange_object, $date_object);

Defines the breaktime for this exchange.

=cut

sub trading_breaks {
    my ($self, $exchange, $when) = @_;

    return $self->get_exchange_open_times($exchange, $when, 'trading_breaks');
}

=head2 closes_early_on

->closes_early_on($exchange_object, $date_object);

Returns the closing time as a L<Date::Utility> instance if the exchange closes early on the given date,
or C<undef>.

=cut

sub closes_early_on {
    my ($self, $exchange, $when) = @_;

    return undef unless $self->trades_on($exchange, $when);

    my $closes_early;
    if (my $listed = $self->_get_partial_trading_for($exchange, 'early_closes')->{$when->days_since_epoch}) {
        return $when->truncate_to_day->plus_time_interval($listed);
    }
    return undef;
}

=head2 opens_late_on

->opens_late_on($exchange_object, $date_object);

Returns true if the exchange opens late on the given date.

=cut

sub opens_late_on {
    my ($self, $exchange, $when) = @_;

    return undef unless $self->trades_on($exchange, $when);

    my $opens_late;

    if (my $listed = $self->_get_partial_trading_for($exchange, 'late_opens')->{$when->days_since_epoch}) {
        $opens_late = $when->truncate_to_day->plus_time_interval($listed);
    }

    return $undef;
}

=head2 seconds_of_trading_between_epochs

->seconds_of_trading_between_epochs($exchange_object, $epoch1, $epoch2);

Get total number of seconds of trading time between two epochs accounting for breaks.

=cut

my $full_day = 86400;

sub seconds_of_trading_between_epochs {
    my ($self, $exchange, $start, $end) = @_;

    my ($start_epoch, $end_epoch) = ($start->epoch, $end->epoch);
    my $result = 0;

    # step 1: calculate non-cached incomplete start-day and end_dates
    my $day_start = $start_epoch - ($start_epoch % $full_day);
    my $day_end   = $end_epoch -   ($end_epoch % $full_day);
    if (($day_start != $start_epoch) && ($start_epoch < $end_epoch)) {
        $result += $self->_computed_trading_seconds($exchange, $start_epoch, min($day_start + 86399, $end_epoch));
        $start_epoch = $day_start + $full_day;
    }
    if (($day_end != $end_epoch) && ($start_epoch < $end_epoch)) {
        $result += $self->_computed_trading_seconds($exchange, max($start_epoch, $day_end), $end_epoch);
        $end_epoch = $day_end;
    }

    # step 2: calculate intermediated values (which are guaranteed to be day-boundary)
    # with cache-aware way
    if ($start_epoch < $end_epoch) {
        $result += $self->_seconds_of_trading_between_epochs_days_boundary($exchange, $start_epoch, $end_epoch);
    }

    return $result;
}

=head2 regular_trading_day_after

->regular_trading_day_after($exchange_object, $date_object);

Returns a Date::Utility object on a trading day where the exchange does not close early or open late after the given date.

=cut

sub regular_trading_day_after {
    my ($self, $exchange, $when) = @_;

    return if $self->closing_on($exchange, $when);

    my $counter = 0;
    my $regular_trading_day = $self->trade_date_after($exchange, $when);
    while ($counter <= 10) {
        my $possible = $regular_trading_day->plus_time_interval($counter . 'd');
        if (    not $self->closes_early_on($exchange, $possible)
            and not $self->opens_late_on($exchange, $possible)
            and $self->trades_on($exchange, $possible))
        {
            $regular_trading_day = $possible;
            last;
        }
        $counter++;
    }

    return $regular_trading_day;
}

=head2 trading_period

->trading_period('HKSE', Date::Utility->new);

Returns an array reference of hash references of open and close time of the given exchange and epoch

=cut

sub trading_period {
    my ($self, $exchange, $when) = @_;

    return [] if not $self->trades_on($exchange, $when);
    my $open = $self->opening_on($exchange, $when);
    my $close = $self->closing_on($exchange, $when);
    my $breaks = $self->trading_breaks($exchange, $when);

    my @times = ($open);
    if (defined $breaks) {
        push @times, @{$_} for @{$breaks};
    }
    push @times, $close;

    my @periods;
    for (my $i = 0; $i < $#times; $i += 2) {
        push @periods,
            {
            open  => $times[$i]->epoch,
            close => $times[$i + 1]->epoch
            };
    }

    return \@periods;
}

=head2 is_holiday_for

Check if it is a holiday for a specific exchange or a country on a specific day

->is_holiday_for('ASX', '2013-01-01'); # Australian exchange holiday
->is_holiday_for('USD', Date::Utility->new); # United States country holiday

Returns the description of the holiday if it is a holiday.

=cut

sub is_holiday_for {
    my ($self, $symbol, $date) = @_;

    my $holidays = $self->_get_holidays_for($symbol);

    return $holidays->{$date->days_since_epoch};
}

=head2 is_in_dst_at

->is_in_dst_at($exchange_object, $date_object);

Is this exchange trading on daylight savings times for the given epoch?

=cut

{
    my %cache;

    sub is_in_dst_at {
        my ($self, $exchange, $epoch) = @_;

        if (my $cache = $cache{$exchange->symbol}{$epoch}) {
            return $cache;
        }

        my $date_object = Date::Utility->new($epoch);
        $cache{$exchange->symbol}{$epoch} = $date_object->is_dst_in_zone($exchange->trading_timezone);

        return $cache{$exchange->symbol}{$epoch};
    }
}

### PRIVATE ###

has _holiday_cache => (
    is      => 'rw',
    default => sub { {} },
);

sub _get_holidays_for {
    my ($self, $symbol) = @_;

    my $cache = $self->_holiday_cache->{$symbol};

    return $cache if $cache;

    my $calendar = $self->calendar->{holidays};
    my %holidays;
    foreach my $date (keys %$calendar) {
        foreach my $holiday_desc (keys %{$calendar->{$date}}) {
            $holidays{Date::Utility->new($date)->days_since_epoch} = $holiday_desc
                if (first { $symbol eq $_ } @{$calendar->{$date}{$holiday_desc}});
        }
    }

    $self->_holiday_cache->{$symbol} = \%holidays;

    return $self->_holiday_cache->{$symbol};
}

sub _is_in_trading_break {
    my ($self, $exchange, $when) = @_;

    $when = Date::Utility->new($when);
    my $in_trading_break = 0;
    if (my $breaks = $self->trading_breaks($exchange, $when)) {
        foreach my $break_interval (@{$breaks}) {
            if ($when->epoch >= $break_interval->[0]->epoch and $when->epoch <= $break_interval->[1]->epoch) {
                $in_trading_break++;
                last;
            }
        }
    }

    return $in_trading_break;
}

=head2 get_exchange_open_times

Query an exchange for valid opening times. Expects 3 parameters:

=over 4

=item * C<$exchange> - a L<Finance::Exchange> instance

=item * C<$date> - a L<Date::Utility>

=item * C<$which> - which market information to request, see below

=back

The possible values for C<$which> include:

=over 4

=item * C<daily_open>

=item * C<daily_close>

=item * C<trading_breaks>

=back

Returns either C<undef>, a single L<Date::Utility>, or an arrayref of L<Date::Utility> instances.

=cut

sub get_exchange_open_times {
    my ($self, $exchange, $date, $which) = @_;

    my $when = (ref $date) ? $date : Date::Utility->new($date);
    my $that_midnight = $self->trading_date_for($exchange, $when);
    my $requested_time;
    if ($self->trades_on($exchange, $that_midnight)) {
        my $dst_key = $self->_times_dst_key($exchange, $that_midnight);
        my $ti = $exchange->market_times->{$dst_key}->{$which};
        my $extended_lunch_hour;
        if ($which eq 'trading_breaks') {
            my $extended_trading_breaks = $exchange->market_times->{$dst_key}->{day_of_week_extended_trading_breaks};
            $extended_lunch_hour = ($extended_trading_breaks and $when->day_of_week == $extended_trading_breaks) ? 1 : 0;
        }
        if ($ti) {
            if (ref $ti eq 'ARRAY') {
                my $trading_breaks = $extended_lunch_hour ? @$ti[1] : @$ti[0];
                my $start_of_break = $that_midnight->plus_time_interval($trading_breaks->[0]);
                my $end_of_break   = $that_midnight->plus_time_interval($trading_breaks->[1]);
                push @{$requested_time}, [$start_of_break, $end_of_break];
            } else {
                $requested_time = $that_midnight->plus_time_interval($ti);
            }
        }
    }
    return $requested_time;    # returns null on no trading days.
}

sub _times_dst_key {
    my ($self, $exchange, $when) = @_;

    my $epoch = (ref $when) ? $when->epoch : $when;

    return 'dst' if $self->is_in_dst_at($exchange, $epoch);
    return 'standard';
}

# get partial trading data for a given exchange
sub _get_partial_trading_for {
    my ($self, $exchange, $type) = @_;

    my $cached = $self->calendar->{$type};

    my %partial_tradings;
    foreach my $epoch (keys %$cached) {
        foreach my $close_time (keys %{$cached->{$epoch}}) {
            my $symbols = $cached->{$epoch}{$close_time};
            $partial_tradings{Date::Utility->new($epoch)->days_since_epoch} = $close_time
                if (first { $exchange->symbol eq $_ } @$symbols);
        }
    }

    return \%partial_tradings;
}

sub _days_between {
    my ($self, $begin, $end) = @_;

    my @days_between = ();

    # Don't include start and end days.
    my $current = Date::Utility->new($begin)->truncate_to_day->plus_time_interval('1d');
    $end = Date::Utility->new($end)->truncate_to_day->minus_time_interval('1d');

    # Generate all days between.
    while (not $current->is_after($end)) {
        push @days_between, $current;
        $current = $current->plus_time_interval('1d');    # Next day, please!
    }

    return \@days_between;
}
Memoize::memoize('_days_between', NORMALIZER => '_normalize_on_just_dates');

## PRIVATE _market_opens
#
# PARAMETERS :
# - time   : the time as a timestamp
#
# RETURNS    : A reference to a hash with the following keys:
# - open   : is set to 1 if the market is currently open, 0 if market is closed
#            but will open, 'undef' if market is closed and will not open again
#            today.
# - closed : undefined if market has not been open yet, otherwise contains the
#            seconds for how long the market was closed.
# - opens  : undefined if market is currently open and does not open anymore today,
#            otherwise the market will open in 'opens' seconds.
# - closes : undefined if open is undef, otherwise market will close in 'closes' seconds.
# - opened : undefined if market is closed, contains the seconds the market has
#            been open.
#
#
########
sub _market_opens {
    my ($self, $exchange, $when) = @_;

    my $date = $when;
    # Figure out which "trading day" we are on
    # even if it differs from the GMT calendar day.
    my $next_day = $date->plus_time_interval('1d')->truncate_to_day;
    my $next_open = $self->opening_on($exchange, $next_day);
    $date = $next_day if ($next_open and not $date->is_before($next_open));

    my $open = $self->opening_on($exchange, $date);
    my $close = $self->closing_on($exchange, $date);

    if (not $open) {

        # date is not a trading day: will not and has not been open today
        my $next_open = $self->opening_on($exchange, $self->trade_date_after($exchange, $when));
        return {
            open   => undef,
            opens  => $next_open->epoch - $when->epoch,
            opened => undef,
            closes => undef,
            closed => undef,
        };
    }

    my $breaks = $self->trading_breaks($exchange, $when);
    # not trading breaks
    if (not $breaks) {
        # Past closing time: opens next trading day, and has been open today
        if ($close and not $when->is_before($close)) {
            return {
                open   => undef,
                opens  => undef,
                opened => $when->epoch - $open->epoch,
                closes => undef,
                closed => $when->epoch - $close->epoch,
            };
        } elsif ($when->is_before($open)) {
            return {
                open   => 0,
                opens  => $open->epoch - $when->epoch,
                opened => undef,
                closes => $close->epoch - $when->epoch,
                closed => undef,
            };
        } elsif ($when->is_same_as($open) or ($when->is_after($open) and $when->is_before($close)) or $when->is_same_same($close)) {
            return {
                open   => 1,
                opens  => undef,
                opened => $when->epoch - $open->epoch,
                closes => $close->epoch - $when->epoch,
                closed => undef,
            };
        }
    } else {
        my @breaks = @$breaks;
        # Past closing time: opens next trading day, and has been open today
        if ($close and not $when->is_before($close)) {
            return {
                open   => undef,
                opens  => undef,
                opened => $when->epoch - $breaks[-1][1]->epoch,
                closes => undef,
                closed => $when->epoch - $close->epoch,
            };
        } elsif ($when->is_before($open)) {
            return {
                open   => 0,
                opens  => $open->epoch - $when->epoch,
                opened => undef,
                closes => $breaks[0][0]->epoch - $when->epoch,
                closed => undef,
            };
        } else {
            my $current_open = $open;
            for (my $i = 0; $i <= $#breaks; $i++) {
                my $int_open  = $breaks[$i][0];
                my $int_close = $breaks[$i][1];
                my $next_open = exists $breaks[$i + 1] ? $breaks[$i + 1][0] : $close;

                if ($when->is_after($current_open) and $when->is_before($int_open)) {
                    return {
                        open   => 1,
                        opens  => undef,
                        opened => $when->epoch - $current_open->epoch,
                        closes => $int_open->epoch - $when->epoch,
                        closed => undef,
                    };
                } elsif ($when->is_same_as($int_open)
                    or ($when->is_after($int_open) and $when->is_before($int_close))
                    or $when->is_same_as($int_close))
                {
                    return {
                        open   => 0,
                        opens  => $int_close->epoch - $when->epoch,
                        opened => undef,
                        closes => $close->epoch - $when->epoch,       # we want to know seconds to official close
                        closed => $when->epoch - $int_open->epoch,
                    };
                } elsif ($when->is_after($int_close) and $when->is_before($next_open)) {
                    return {
                        open   => 1,
                        opens  => undef,
                        opened => $when->epoch - $int_close->epoch,
                        closes => $next_open->epoch - $when->epoch,
                        closed => undef,
                    };
                }
            }

        }
    }

    return;
}

## PRIVATE method _seconds_of_trading_between_epochs_days_boundary
#
# there is a strict assumption, that start and end epoch are day boundaries
#
my %cached_seconds_for_interval;    # key ${epoch1}-${epoch2}, value: seconds

sub _seconds_of_trading_between_epochs_days_boundary {
    my ($self, $exchange, $start_epoch, $end_epoch) = @_;

    my $cache_key = join('-', $exchange->symbol, $start_epoch, $end_epoch);
    my $result = $cached_seconds_for_interval{$cache_key} //= do {
        my $head = $self->_computed_trading_seconds($exchange, $start_epoch, $start_epoch + 86399);
        if ($end_epoch - $start_epoch > $full_day - 1) {
            my $tail = $self->_seconds_of_trading_between_epochs_days_boundary($exchange, $start_epoch + $full_day, $end_epoch);
            $head + $tail;
        }
    };

    return $result;
}

## PRIVATE method _computed_trading_seconds
#
# This one ACTUALLY does the heavy lifting of determining the number of trading seconds in an intraday period.
#
sub _computed_trading_seconds {
    my ($self, $exchange, $start, $end) = @_;

    my $total_trading_time = 0;
    my $when               = Date::Utility->new($start);

    if ($self->trades_on($exchange, $when)) {

        # Do the full computation.
        my $opening_epoch = $self->opening_on($exchange, $when)->epoch;
        my $closing_epoch = $self->closing_on($exchange, $when)->epoch;

# Total trading time left in interval. This is always between 0 to $period_secs_basis.
# This will automatically take care of early close because market close will just be the early close time.
        my $total_trading_time_including_lunchbreaks =
            max(min($closing_epoch, $end), $opening_epoch) - min(max($opening_epoch, $start), $closing_epoch);

        my $total_lunch_break_time = 0;

# Now take care of lunch breaks. But handle early close properly. It could be that
# the early close already wipes out the need to handle lunch breaks.
# Handle early close. For example on 24 Dec 2009, HKSE opens at 2:00, and stops
# for lunch at 4:30 and never reopens. In that case the value of $self->closing_on($thisday)
# is 4:30, and lunch time between 4:30 to 6:00 is no longer relevant.
        if (my $breaks = $self->trading_breaks($exchange, $when)) {
            for my $break_interval (@{$breaks}) {
                my $interval_open  = $break_interval->[0];
                my $interval_close = $break_interval->[1];
                my $close_am       = min($interval_open->epoch, $closing_epoch);
                my $open_pm        = min($interval_close->epoch, $closing_epoch);

                $total_lunch_break_time = max(min($open_pm, $end), $close_am) - min(max($close_am, $start), $open_pm);

                if ($total_lunch_break_time < 0) {
                    die 'Total lunch break time between ' . $start . '] and [' . $end . '] for exchange[' . $self->exchange->symbol . '] is negative';
                }
            }
        }

        $total_trading_time = $total_trading_time_including_lunchbreaks - $total_lunch_break_time;
        if ($total_trading_time < 0) {
            croak 'Total trading time (minus lunch) between '
                . $start
                . '] and ['
                . $end
                . '] for exchange['
                . $self->exchange->symbol
                . '] is negative.';
        }
    }

    return $total_trading_time;
}

## PRIVATE static methods
#
# Many of these functions don't change their results if asked for the
# same dates many times.  Let's exploit that for time over space
#
# This actually comes up in our pricing where we have to do many interpolations
# over the same ranges on different values.
#
# This attaches to the static method on the class for the lifetime of this instance.
# Since we only want the cache for our specific symbol, we need to include an identifier.

sub _normalize_on_dates {
    my ($self, $exchange, @dates) = @_;

    return join '|', ($exchange->symbol, map { Date::Utility->new($_)->days_since_epoch } @dates);
}

sub _normalize_on_just_dates {
    my ($self, @dates) = @_;

    return join '|', (map { Date::Utility->new($_)->days_since_epoch } @dates);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
