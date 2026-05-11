package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/coder"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/config"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/handler"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		// Logger not yet configured; fall back to default stderr.
		slog.Error("config load failed", "err", err)
		os.Exit(2)
	}

	logger := newLogger(cfg.LogLevel)
	slog.SetDefault(logger)

	coderClient := coder.New(cfg.CoderURL, cfg.CoderToken, 15*time.Second)

	mux := http.NewServeMux()
	h := handler.New(cfg, coderClient, logger)
	h.Register(mux)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("bridge listening", "addr", cfg.ListenAddr, "coder_url", cfg.CoderURL)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown initiated")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	logger.Info("shutdown complete")
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
}
