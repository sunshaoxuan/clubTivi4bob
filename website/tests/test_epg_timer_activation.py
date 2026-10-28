"""EPG timer activation must not depend on an already elapsed boot deadline."""
from configparser import ConfigParser
from pathlib import Path

import pytest

DEPLOY = Path(__file__).parents[1] / 'deploy'
TIMERS = [('validator','2min','60s'), ('discovery','3min','60s'),
          ('schedules','3min','60s'), ('publisher','4min','60s'),
          ('source-discovery','3min','2min')]


def configuration(name):
    parser = ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read(DEPLOY / ('bobtv-epg-' + name + '.timer'))
    return parser


@pytest.mark.parametrize('name,activation,interval', TIMERS)
def test_each_activation_primes_a_first_run_with_original_stagger(name, activation, interval):
    timer = configuration(name)['Timer']
    assert timer['OnActiveSec'] == activation
    assert 'OnBootSec' not in timer and 'OnStartupSec' not in timer


@pytest.mark.parametrize('name,activation,interval', TIMERS)
def test_ordinary_cadence_remains_relative_to_completed_bounded_work(name, activation, interval):
    timer = configuration(name)['Timer']
    assert timer['OnUnitInactiveSec'] == interval
    assert 'OnUnitActiveSec' not in timer and 'OnCalendar' not in timer
    assert timer['AccuracySec'] == '10s'
    assert timer['RandomizedDelaySec'] == '10s'


@pytest.mark.parametrize('name,activation,interval', TIMERS)
def test_same_named_worker_and_boot_enablement_are_retained(name, activation, interval):
    unit = configuration(name)
    assert unit['Install']['WantedBy'] == 'timers.target'
    assert (DEPLOY / ('bobtv-epg-' + name + '.service')).is_file()
    assert 'Unit' not in unit['Timer']
    assert unit['Timer']['Persistent'] == 'true'
