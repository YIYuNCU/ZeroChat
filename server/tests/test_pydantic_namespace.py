"""Regression tests for pydantic protected-namespace warnings.

`model_max_context_length` (roles) and `model_thinking_settings` (settings) both start
with `model_`, which old pydantic versions treat as a protected namespace and report as
a `UserWarning` while the model class is created. The models therefore pin
`protected_namespaces=()`; these tests fail loudly if that configuration is dropped.
"""
import unittest
import warnings

from pydantic import BaseModel, ConfigDict


def namespace_warnings(model_cls) -> list[str]:
    """Return protected-namespace warnings raised while collecting ``model_cls`` fields."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        # Rebuilding replays field collection, which is where the warning fires.
        model_cls.model_rebuild(force=True)
    return [
        str(item.message)
        for item in caught
        if "protected namespace" in str(item.message)
    ]


class ProtectedNamespaceTests(unittest.TestCase):
    def test_role_models_are_configured_without_protected_namespaces(self):
        from routers import roles

        for model_cls in (roles.RoleCreate, roles.RoleUpdate):
            with self.subTest(model=model_cls.__name__):
                self.assertEqual(
                    tuple(model_cls.model_config.get("protected_namespaces") or ()),
                    (),
                )
                self.assertEqual(namespace_warnings(model_cls), [])

    def test_settings_models_are_configured_without_protected_namespaces(self):
        from routers import settings

        for model_cls in (settings.SettingsUpdate, settings.ModelThinkingSettings):
            with self.subTest(model=model_cls.__name__):
                self.assertEqual(
                    tuple(model_cls.model_config.get("protected_namespaces") or ()),
                    (),
                )
        self.assertEqual(namespace_warnings(settings.SettingsUpdate), [])

    def test_explicit_empty_protected_namespaces_allows_model_prefixed_fields(self):
        """Guard the guard: the pinned configuration is what suppresses the conflict."""
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")

            class Guarded(BaseModel):
                model_config = ConfigDict(protected_namespaces=())
                model_thing: int = 0

        self.assertEqual(
            [
                str(item.message)
                for item in caught
                if "protected namespace" in str(item.message)
            ],
            [],
        )
        self.assertEqual(Guarded(model_thing=1).model_thing, 1)


if __name__ == "__main__":
    unittest.main()
