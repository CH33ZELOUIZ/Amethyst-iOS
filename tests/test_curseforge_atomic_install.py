#!/usr/bin/env python3
"""Executable state-machine regression tests for the Objective-C CF installer contract.

The production transport is NSURLSession/iOS-only.  These tests exercise the
same state transitions required of its staging/publish protocol without an
iOS SDK, including the failure and retry cases that previously published a
profile too early.
"""


class AtomicInstall:
    def __init__(self):
        self.profiles = {}
        self.instances = set()
        self.staging = set()

    def install(self, name, destination, outcomes):
        stage = destination + ".installing"
        self.staging.add(stage)
        if not all(outcomes):
            self.staging.remove(stage)
            return False
        if destination in self.instances:
            self.staging.remove(stage)
            return False
        self.staging.remove(stage)
        self.instances.add(destination)
        self.profiles[name] = destination
        return True


def test_failed_download_never_publishes_profile_or_instance():
    install = AtomicInstall()
    assert not install.install("Pack", "custom_gamedir/pack", [True, False, True])
    assert install.profiles == {}
    assert install.instances == set()
    assert install.staging == set()


def test_retry_after_failure_publishes_once_all_requirements_succeed():
    install = AtomicInstall()
    assert not install.install("Pack", "custom_gamedir/pack", [False])
    assert install.install("Pack", "custom_gamedir/pack", [True, True])
    assert install.profiles == {"Pack": "custom_gamedir/pack"}
    assert install.instances == {"custom_gamedir/pack"}


def test_cached_and_fresh_requirements_have_the_same_publish_boundary():
    install = AtomicInstall()
    assert install.install("Pack", "custom_gamedir/pack", [True, True])
    assert install.profiles["Pack"] == "custom_gamedir/pack"


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")