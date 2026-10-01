"""Validate the real generated chain and IP identity; never touch production keys."""
import ssl
import tempfile
import unittest
from pathlib import Path

import private_ca
from cryptography import x509
from cryptography.x509.oid import ExtendedKeyUsageOID


class PrivateCaTests(unittest.TestCase):
    def test_ca_and_leaf_constraints_and_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ca = private_ca.create_ca(root / "ca")
            leaf = private_ca.issue(root / "ca", root / "server", ["192.168.0.69"])
            leaf.verify_directly_issued_by(ca)
            self.assertTrue(ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
            self.assertFalse(leaf.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
            self.assertEqual(leaf.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value,
                             x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]))
            names = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            self.assertEqual(str(names.get_values_for_type(x509.IPAddress)[0]), "192.168.0.69")
            context = ssl.create_default_context(cafile=str(root / "ca/ca.crt"))
            self.assertTrue(context.check_hostname)
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            for path in (root / "ca/ca.key", root / "server/server.key"):
                self.assertEqual(path.stat().st_mode & 0o077, 0)
            with self.assertRaises(ValueError):
                private_ca.create_ca(root / "ca")
            with self.assertRaises(ValueError):
                private_ca.issue(root / "ca", root / "server", ["192.168.0.69"])
            with self.assertRaises(ValueError):
                private_ca.issue(root / "ca", root / "bad", ["0.0.0.0"])


if __name__ == "__main__":
    unittest.main()
