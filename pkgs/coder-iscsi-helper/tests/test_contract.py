import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from helper import CapabilityStore, validate_size_gb, validate_workspace


class ContractTests(unittest.TestCase):
    def test_workspace_name_accepts_lowercase_dns_safe_name(self):
        self.assertEqual(validate_workspace("coder-demo-01"), "coder-demo-01")

    def test_workspace_name_rejects_unsafe_name(self):
        with self.assertRaises(ValueError):
            validate_workspace("Coder/demo")

    def test_size_is_bounded_integer(self):
        self.assertEqual(validate_size_gb(50), 50)
        with self.assertRaises(ValueError):
            validate_size_gb(9)
        with self.assertRaises(ValueError):
            validate_size_gb("50")

    def test_capability_is_required_and_not_stored_in_cleartext(self):
        store = CapabilityStore()
        capability = store.acquire("coder-demo")
        self.assertTrue(store.authorize("coder-demo", capability))
        self.assertFalse(store.authorize("coder-other", capability))
        self.assertNotIn(capability, store.serialized_state())
        store.release("coder-demo", capability)
        self.assertFalse(store.authorize("coder-demo", capability))


if __name__ == "__main__":
    unittest.main()
