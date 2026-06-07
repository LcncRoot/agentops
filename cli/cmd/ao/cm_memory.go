package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	cmContextTimeout    = 12 * time.Second
	cmReflectionTimeout = 15 * time.Second
)

type cmPendingCandidate struct {
	Title string
	Body  string
}

func runOptionalCMContext(cwd, query string) error {
	query = strings.TrimSpace(query)
	if query == "" || os.Getenv("AGENTOPS_CM_DISABLED") == "1" {
		return nil
	}
	if _, err := exec.LookPath("cm"); err != nil {
		return nil
	}

	raw, err := runCMCommand(cwd, cmContextTimeout, "context", query, "--json")
	if err != nil {
		return err
	}
	if len(raw) == 0 {
		return nil
	}

	rawPath := filepath.Join(cwd, ".agents", "ao", "context", "cm-context.json")
	if err := os.MkdirAll(filepath.Dir(rawPath), 0o750); err != nil {
		return fmt.Errorf("create cm context dir: %w", err)
	}
	if err := atomicWriteFile(rawPath, append(raw, '\n'), 0o600); err != nil {
		return fmt.Errorf("write cm context raw artifact: %w", err)
	}

	briefingPath := filepath.Join(cwd, ".agents", "briefings", "cm-context.md")
	if err := os.MkdirAll(filepath.Dir(briefingPath), 0o750); err != nil {
		return fmt.Errorf("create cm briefing dir: %w", err)
	}
	content := renderCMContextBriefing(query, rawPath, raw)
	if err := atomicWriteFile(briefingPath, []byte(content), 0o600); err != nil {
		return fmt.Errorf("write cm context briefing: %w", err)
	}
	return nil
}

func runOptionalCMReflection(cwd, transcriptPath string) error {
	transcriptPath = strings.TrimSpace(transcriptPath)
	if transcriptPath == "" || os.Getenv("AGENTOPS_CM_DISABLED") == "1" {
		return nil
	}
	if _, err := exec.LookPath("cm"); err != nil {
		return nil
	}

	raw, err := runCMCommand(cwd, cmReflectionTimeout, "onboard", "read", transcriptPath, "--template", "--json")
	if err != nil {
		return err
	}
	if len(raw) == 0 {
		return nil
	}

	ts := time.Now().UTC()
	provenancePath := filepath.Join(cwd, ".agents", "ao", "provenance", "cm", ts.Format("20060102T150405Z")+"-reflection.json")
	if err := os.MkdirAll(filepath.Dir(provenancePath), 0o750); err != nil {
		return fmt.Errorf("create cm provenance dir: %w", err)
	}
	if err := atomicWriteFile(provenancePath, append(raw, '\n'), 0o600); err != nil {
		return fmt.Errorf("write cm reflection provenance: %w", err)
	}

	candidates := extractCMPendingCandidates(raw)
	if len(candidates) == 0 {
		fallback := strings.TrimSpace(extractCMPrimaryText(raw))
		if fallback != "" {
			candidates = []cmPendingCandidate{{
				Title: "CM Reflection",
				Body:  fallback,
			}}
		}
	}
	if len(candidates) == 0 {
		return nil
	}

	pendingDir := filepath.Join(cwd, ".agents", "knowledge", "pending")
	if err := os.MkdirAll(pendingDir, 0o750); err != nil {
		return fmt.Errorf("create cm pending dir: %w", err)
	}
	for i, candidate := range candidates {
		filename := fmt.Sprintf("%s-cm-reflection-%d.md", ts.Format("2006-01-02"), i+1)
		path := filepath.Join(pendingDir, filename)
		doc := renderCMPendingCandidate(candidate, provenancePath, transcriptPath, ts)
		if err := atomicWriteFile(path, []byte(doc), 0o600); err != nil {
			return fmt.Errorf("write cm pending candidate %s: %w", path, err)
		}
	}
	return nil
}

func runCMCommand(cwd string, timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "cm", args...)
	cmd.Dir = cwd
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("cm %s timed out", strings.Join(args, " "))
	}
	if err != nil {
		return nil, fmt.Errorf("cm %s: %w", strings.Join(args, " "), err)
	}
	return out, nil
}

func renderCMContextBriefing(query, rawPath string, raw []byte) string {
	var sb strings.Builder
	sb.WriteString("# CM Context\n\n")
	fmt.Fprintf(&sb, "- Query: %s\n", query)
	fmt.Fprintf(&sb, "- Raw artifact: %s\n", rawPath)
	sb.WriteString("- Source: `cm context --json`\n\n")
	sb.WriteString("## Summary\n")
	summary := strings.TrimSpace(extractCMPrimaryText(raw))
	if summary == "" {
		sb.WriteString("- CM returned JSON, but no summary-like text was detected.\n")
	} else {
		for _, line := range strings.Split(summary, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			fmt.Fprintf(&sb, "- %s\n", line)
		}
	}
	return sb.String()
}

func renderCMPendingCandidate(candidate cmPendingCandidate, provenancePath, transcriptPath string, ts time.Time) string {
	title := strings.TrimSpace(candidate.Title)
	if title == "" {
		title = "CM Reflection"
	}
	body := strings.TrimSpace(candidate.Body)
	return fmt.Sprintf(`---
date: %s
type: learning
source: cm-reflection
provenance_path: %s
transcript_path: %s
---

# %s

%s
`, ts.Format("2006-01-02"), provenancePath, transcriptPath, title, body)
}

func extractCMPrimaryText(raw []byte) string {
	var payload any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return strings.TrimSpace(string(raw))
	}
	return strings.TrimSpace(firstCMText(payload))
}

func firstCMText(value any) string {
	switch typed := value.(type) {
	case map[string]any:
		for _, key := range []string{"summary", "briefing", "content", "text", "message", "body", "description"} {
			if text := strings.TrimSpace(anyToString(typed[key])); text != "" {
				return text
			}
		}
		for _, key := range []string{"artifacts", "candidates", "items", "memories", "recommendations", "suggestions"} {
			if text := firstCMText(typed[key]); text != "" {
				return text
			}
		}
		for _, value := range typed {
			if text := firstCMText(value); text != "" {
				return text
			}
		}
	case []any:
		for _, item := range typed {
			if text := firstCMText(item); text != "" {
				return text
			}
		}
	case string:
		return strings.TrimSpace(typed)
	}
	return ""
}

func extractCMPendingCandidates(raw []byte) []cmPendingCandidate {
	var payload any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil
	}

	var candidates []cmPendingCandidate
	collectCMPendingCandidates(payload, &candidates)
	return dedupeCMPendingCandidates(candidates)
}

func collectCMPendingCandidates(value any, candidates *[]cmPendingCandidate) {
	switch typed := value.(type) {
	case map[string]any:
		for _, key := range []string{"artifacts", "candidates", "items", "memories", "recommendations", "suggestions"} {
			if child, ok := typed[key]; ok {
				collectCMPendingCandidates(child, candidates)
			}
		}

		title := firstNonEmptyTrimmed(
			anyToString(typed["title"]),
			anyToString(typed["name"]),
			anyToString(typed["heading"]),
			anyToString(typed["label"]),
		)
		body := firstNonEmptyTrimmed(
			anyToString(typed["body"]),
			anyToString(typed["content"]),
			anyToString(typed["text"]),
			anyToString(typed["summary"]),
			anyToString(typed["description"]),
			anyToString(typed["recommendation"]),
		)
		if strings.TrimSpace(body) != "" {
			*candidates = append(*candidates, cmPendingCandidate{
				Title: strings.TrimSpace(title),
				Body:  strings.TrimSpace(body),
			})
		}
	case []any:
		for _, item := range typed {
			collectCMPendingCandidates(item, candidates)
		}
	}
}

func dedupeCMPendingCandidates(candidates []cmPendingCandidate) []cmPendingCandidate {
	seen := make(map[string]struct{}, len(candidates))
	var deduped []cmPendingCandidate
	for _, candidate := range candidates {
		body := strings.TrimSpace(candidate.Body)
		if body == "" {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(candidate.Title)) + "\n" + body
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		deduped = append(deduped, candidate)
	}
	return deduped
}

func anyToString(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	default:
		data, err := json.Marshal(typed)
		if err != nil {
			return ""
		}
		return string(data)
	}
}
