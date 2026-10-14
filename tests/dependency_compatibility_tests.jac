"""Run dependency compatibility checks with the project's actual Jac modules."""
import unittest;

test "dependency upgrades preserve stored data and Google auth transport" {
    suite = unittest.defaultTestLoader.discover("tests", pattern="test_dependency_compatibility.py");
    result = unittest.TextTestRunner(verbosity=2).run(suite);
    assert result.wasSuccessful();
}
