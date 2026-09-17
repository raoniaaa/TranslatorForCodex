package credentials

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalPersistencePermissionsAndDelete(t *testing.T) {
	s := Local{Directory: filepath.Join(t.TempDir(), "credentials")}
	if err := s.Set("fixture-id", "fixture-secret"); err != nil {
		t.Fatal(err)
	}
	restarted := Local{Directory: s.Directory}
	key, err := restarted.Get("fixture-id")
	if err != nil || key != "fixture-secret" {
		t.Fatal("local restart failed")
	}
	for path, mode := range map[string]os.FileMode{s.Directory: 0700, filepath.Join(s.Directory, "fixture-id.key"): 0600} {
		stat, err := os.Stat(path)
		if err != nil || stat.Mode().Perm() != mode {
			t.Fatal("incorrect private file permissions")
		}
	}
	if err := s.Set("fixture-id", "updated-fixture"); err != nil {
		t.Fatal(err)
	}
	key, _ = s.Get("fixture-id")
	if key != "updated-fixture" {
		t.Fatal("update failed")
	}
	if err := s.Delete("fixture-id"); err != nil {
		t.Fatal(err)
	}
	key, err = restarted.Get("fixture-id")
	if key != "" || err != nil {
		t.Fatal("deletion failed")
	}
	if err := s.Set("../outside", "fixture"); err == nil {
		t.Fatal("accepted invalid credential path")
	}
}
