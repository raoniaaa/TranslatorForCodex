// Package credentials stores API keys in private local files.
package credentials

type Store interface {
	Get(id string) (string, error)
	Set(id, key string) error
	Delete(id string) error
}
