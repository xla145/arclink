import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("r2_cors", Path(__file__).with_name("r2-cors.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Client:
    def __init__(self, rules=None): self.rules = rules
    def get_bucket_cors(self, **_):
        if self.rules is None:
            error = type("Error", (Exception,), {"response": {"Error": {"Code": "NoSuchCORSConfiguration"}}})()
            raise error
        return {"CORSRules": self.rules}
    def put_bucket_cors(self, **kwargs): self.rules = kwargs["CORSConfiguration"]["CORSRules"]

class CorsTests(unittest.TestCase):
    def test_preserves_existing_rules(self):
        client = Client([{"AllowedOrigins": ["https://other.example"], "AllowedMethods": ["GET"]}])
        self.assertTrue(module.ensure_cors(client, "oss"))
        self.assertEqual(len(client.rules), 2)
    def test_missing_configuration_creates_rule(self):
        client = Client()
        self.assertTrue(module.ensure_cors(client, "oss"))
        self.assertEqual(client.rules[0]["AllowedOrigins"], [module.ORIGIN])

    def test_access_denied_does_not_replace_existing_rules(self):
        class Denied(Client):
            def get_bucket_cors(self, **_):
                error = RuntimeError("access denied")
                error.response = {"Error": {"Code": "AccessDenied"}}
                raise error
        client = Denied([{"unrelated": True}])
        with self.assertRaises(RuntimeError): module.ensure_cors(client, "oss")
        self.assertEqual(client.rules, [{"unrelated": True}])

    def test_is_idempotent(self):
        client = Client([])
        self.assertTrue(module.ensure_cors(client, "oss"))
        self.assertFalse(module.ensure_cors(client, "oss"))

if __name__ == "__main__": unittest.main()
