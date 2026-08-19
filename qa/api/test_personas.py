"""The suite must be able to create the identities it tests as.

The live database has no manager, and every seeded account demands a password
reset, so nothing here depends on data that happens to be present.
"""
from qa.personas import provision, token_for


def test_provision_creates_all_four_roles(base_url):
    people = provision(base_url)
    assert set(people) == {"manager", "supervisor", "executive", "other_manager"}
    assert people["manager"].role == "manager"
    # The tenant probe must live on a different site or it proves nothing.
    assert people["other_manager"].site != people["manager"].site


def test_each_persona_can_log_in_without_a_manual_reset(base_url):
    """`POST /admin/users` always sets must_reset_password, so provisioning
    has to drive the change-password flow itself."""
    people = provision(base_url)
    for name, p in people.items():
        assert token_for(base_url, p), f"{name} could not log in"


def test_provision_is_idempotent(base_url):
    first = provision(base_url)
    second = provision(base_url)
    assert {k: v.handle for k, v in first.items()} == {
        k: v.handle for k, v in second.items()
    }
