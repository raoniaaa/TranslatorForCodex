package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"translator/internal/web"
)

func main() {
	demo := flag.Bool("demo", false, "Only run the settings and translation playground")
	hosted := flag.Bool("native-hosted", false, "Communicate with the native application over stdio")
	flag.Parse()
	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	a, err := web.Start(filepath.Dir(executable), *demo, *hosted)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if *hosted {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"type": "settings", "url": a.URL})
	} else {
		fmt.Println("Translator settings:", a.URL)
	}
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	select {
	case <-quit:
	case <-a.Done():
	}
	a.Close()
}
