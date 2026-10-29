package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var upgradeablePackageLinePattern = regexp.MustCompile(`^[^\s/]+/[^\s]+\s+`)

type controllerReport struct {
	AgentID                  string   `json:"agent_id"`
	Hostname                 string   `json:"hostname"`
	Version                  string   `json:"version"`
	RebootRequired           bool     `json:"reboot_required"`
	UpgradeablePackages      []string `json:"upgradeable_packages"`
	UpgradeablePackagesCount int      `json:"upgradeable_packages_count"`
	RunningCommandID         string   `json:"running_command_id,omitempty"`
	LastError                string   `json:"last_error,omitempty"`
	HeartbeatInterval        int      `json:"heartbeat_interval"`
	SentAt                   string   `json:"sent_at"`
}

type controllerCommand struct {
	ID     string `json:"id"`
	Action string `json:"action"`
}

type controllerCommandsResponse struct {
	ServerTime string              `json:"server_time"`
	Commands   []controllerCommand `json:"commands"`
}

type controllerResult struct {
	AgentID string `json:"agent_id,omitempty"`
	Success bool   `json:"success"`
	Output  string `json:"output,omitempty"`
	Error   string `json:"error,omitempty"`
}

func controllerURL(config Config, path string) string {
	return strings.TrimRight(config.Controller.URL, "/") + path
}

func controllerClient() *http.Client {
	return &http.Client{Timeout: 15 * time.Second}
}

func sendPulse(config Config, rebootRequired bool, packages []string, runningCommandID string, lastError string) []controllerCommand {
	if !config.Controller.Enabled || strings.TrimSpace(config.Controller.URL) == "" {
		return nil
	}
	hostname, _ := os.Hostname()
	pulse := controllerReport{
		AgentID: config.AgentID, Hostname: hostname, Version: agentVersion,
		RebootRequired:      rebootRequired,
		UpgradeablePackages: packages, UpgradeablePackagesCount: len(packages),
		RunningCommandID: runningCommandID, LastError: lastError,
		HeartbeatInterval: config.Controller.Interval,
		SentAt:            time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(pulse)
	if err != nil {
		fmt.Printf("[%s] Error encoding controller report: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		return nil
	}
	req, err := http.NewRequest(http.MethodPost, controllerURL(config, "/api/v1/agents/pulse"), bytes.NewReader(data))
	if err != nil {
		return nil
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+config.Controller.Token)
	resp, err := controllerClient().Do(req)
	if err != nil {
		fmt.Printf("[%s] Controller report failed: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		fmt.Printf("[%s] Controller report rejected: %s %s\n", time.Now().Format("2006-01-02 15:04:05"), resp.Status, strings.TrimSpace(string(body)))
		return nil
	}
	var payload controllerCommandsResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		logControllerEvent("Invalid controller pulse response: %v", err)
		return nil
	}
	return payload.Commands
}

func executeControllerCommand(config Config, hostname string, command controllerCommand) {
	logControllerEvent("Received controller command %s (%s)", command.ID, command.Action)
	result := controllerResult{AgentID: config.AgentID, Success: false}
	switch command.Action {
	case "upgrade":
		logControllerEvent("Starting package upgrade for command %s", command.ID)
		output, commandErr := runPackageUpgrade()
		result.Output, result.Error, result.Success = output, errorString(commandErr), commandErr == nil
	case "reboot":
		logControllerEvent("Starting system reboot for command %s", command.ID)
		commandErr := exec.Command("systemctl", "reboot").Run()
		if commandErr == nil {
			result.Output = "systemctl reboot command accepted"
		}
		result.Error, result.Success = errorString(commandErr), commandErr == nil
	default:
		result.Error = "unsupported action"
	}
	if result.Success {
		logControllerEvent("Command %s completed successfully", command.ID)
	} else {
		logControllerEvent("Command %s failed: %s", command.ID, result.Error)
	}
	postCommandResult(config, hostname, command.ID, result)
}

func postCommandResult(config Config, hostname, commandID string, result controllerResult) {
	data, err := json.Marshal(result)
	if err != nil {
		return
	}
	req, err := http.NewRequest(http.MethodPost, controllerURL(config, "/api/v1/agents/"+url.PathEscape(hostname)+"/commands/"+url.PathEscape(commandID)+"/result"), bytes.NewReader(data))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+config.Controller.Token)
	resp, err := controllerClient().Do(req)
	if err != nil {
		logControllerEvent("Failed to post result for command %s: %v", commandID, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		logControllerEvent("Controller rejected result for command %s: %s", commandID, resp.Status)
	}
}

func logControllerEvent(format string, args ...interface{}) {
	fmt.Printf("[%s] "+format+"\n", append([]interface{}{time.Now().Format("2006-01-02 15:04:05")}, args...)...)
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func getUpgradeablePackages() ([]string, error) {
	cmd := exec.Command("apt", "list", "--upgradeable")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("apt list --upgradeable failed: %w: %s", err, strings.TrimSpace(string(output)))
	}

	simulation, err := exec.Command("apt-get", "-s", "-o", "Debug::NoLocking=true", "upgrade").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("apt-get simulation failed: %w: %s", err, strings.TrimSpace(string(simulation)))
	}
	installable := make(map[string]struct{})
	for _, line := range strings.Split(string(simulation), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "Inst" {
			installable[fields[1]] = struct{}{}
		}
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	packages := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || !upgradeablePackageLinePattern.MatchString(trimmed) {
			continue
		}
		packageName := strings.SplitN(trimmed, "/", 2)[0]
		if _, ok := installable[packageName]; !ok {
			continue
		}
		packages = append(packages, trimmed)
	}
	return packages, nil
}

func runPackageUpgrade() (string, error) {
	cmd := exec.Command("bash", "-lc", "DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=600 update && DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=600 upgrade -y")
	output, err := cmd.CombinedOutput()
	return string(output), err
}
