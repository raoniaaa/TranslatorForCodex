package credentials

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
)

// Local stores credentials in private, plaintext files, as requested by the user.
// The settings file holds only an ID; secrets are never returned to the GUI.
type Local struct{ Directory string }

var validID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func ConfigDir() string {
	if dir := os.Getenv("TRANSLATOR_CONFIG_DIR"); dir != "" {
		return dir
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(base, "CodexTranslator")
}
func New(_ string) Store {
	dir := ConfigDir()
	if dir != "" {
		dir = filepath.Join(dir, "credentials")
	}
	return Local{Directory: dir}
}
func (s Local) path(id string) (string, error) {
	if s.Directory == "" || !validID.MatchString(id) {
		return "", errors.New("本地密钥位置无效")
	}
	return filepath.Join(s.Directory, id+".key"), nil
}
func (s Local) Get(id string) (string, error) {
	path, err := s.path(id)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", errors.New("无法读取本地密钥文件")
	}
	return string(data), nil
}
func (s Local) Set(id, key string) error {
	path, err := s.path(id)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(s.Directory, 0700); err != nil {
		return errors.New("无法创建本地密钥目录")
	}
	if err := os.Chmod(s.Directory, 0700); err != nil {
		return errors.New("无法设置密钥目录权限")
	}
	file, err := os.CreateTemp(s.Directory, ".key-*")
	if err != nil {
		return errors.New("无法保存本地密钥")
	}
	defer os.Remove(file.Name())
	if _, err = file.WriteString(key); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(file.Name(), path)
	}
	if err != nil {
		return errors.New("无法保存本地密钥")
	}
	return nil
}
func (s Local) Delete(id string) error {
	path, err := s.path(id)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return errors.New("无法删除本地密钥")
	}
	return nil
}
