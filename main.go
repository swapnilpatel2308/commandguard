package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

const CONFIG_PATH = "/etc/commandguard/command_guard.yaml"

type Rule struct {
	Name                string   `yaml:"name"`
	Description         string   `yaml:"description"`
	Filter              string   `yaml:"filter"`
	InputPrompt         string   `yaml:"input_prompt"`
	AllowInput          string   `yaml:"allow_input"`
	ReasonRequire       bool     `yaml:"reason_require"`
	ReasonRequirePrompt string   `yaml:"reason_require_prompt"`
	Deny                bool     `yaml:"deny"`
	DenyPrompt          string   `yaml:"deny_prompt"`
	Enabled             bool     `yaml:"enabled"`
	NotAllowOutputText  string   `yaml:"not_allow_output_text"`
	AllowedUsers        []string `yaml:"allowd_users"`
	Commands            []string `yaml:"commands"`
	CommandOutputDebug  bool     `yaml:"command_output_debug"`
}

type Config struct {
	Rules []Rule `yaml:"rules"`
}


func applyRuleDefaults(r *Rule) {
	set := func(dst *string, val string) {
		if *dst == "" {
			*dst = val
		}
	}

	set(&r.InputPrompt, "Are you sure? (Y/N)")
	set(&r.AllowInput, "Y")
	set(&r.ReasonRequirePrompt, "Enter reason: ")
	set(&r.NotAllowOutputText, "Command denied !!")

	if len(r.AllowedUsers) == 0 {
		r.AllowedUsers = []string{"*"}
	}
	if !r.Enabled {
		r.Enabled = true
	}
}

func matchFilter(text, pattern string) bool {
	re := regexp.QuoteMeta(pattern)
	re = strings.ReplaceAll(re, `\*`, ".*")
	re = strings.ReplaceAll(re, `\?`, ".")
	re = "^" + re + "$"

	ok, _ := regexp.MatchString(re, strings.TrimSpace(text))
	return ok
}

func isUserAllowed(user string, allowed []string) bool {
	for _, u := range allowed {
		if matchFilter(user, u) {
			return true
		}
	}
	return false
}

func readInput(prompt string) string {
	fmt.Print(prompt)
	in := bufio.NewReader(os.Stdin)
	text, _ := in.ReadString('\n')
	return strings.TrimSpace(text)
}

func runCommandNonInteractive(command string) (string, error) {
	if strings.TrimSpace(command) == "" {
		return "", errors.New("empty command")
	}

	args := strings.Fields(command)
	cmd := exec.Command(args[0], args[1:]...)
	out, err := cmd.CombinedOutput()

	if err != nil {
		return string(out), fmt.Errorf("command failed: %w", err)
	}

	return string(out), nil
}

func processCommand(args []string, user string, cfg *Config) int {
	baseCmd := strings.Join(args, " ")
	// fmt.Println(baseCmd)

	for _, rule := range cfg.Rules {

		if !rule.Enabled || !matchFilter(baseCmd, rule.Filter) {
			continue
		}

		if !isUserAllowed(user, rule.AllowedUsers) {
			fmt.Println("User is not allowed.")
			return 1
		}

		fmt.Println(rule.Description)

		if rule.Deny {
			fmt.Println(rule.DenyPrompt)
			return 1
		}

		reason := ""
		if rule.ReasonRequire {
			reason = readInput(rule.ReasonRequirePrompt)
		}

		choice := strings.ToLower(readInput(rule.InputPrompt + ": "))
		if choice != strings.ToLower(rule.AllowInput) {
			fmt.Println(rule.NotAllowOutputText)
			return 1
		}

		for _, cmd := range rule.Commands {
			fullCmd := fmt.Sprintf("%s %s %s", cmd, reason, baseCmd)
			output, err := runCommandNonInteractive(fullCmd)
			if err != nil {
				fmt.Println("Error while running command:", cmd)
				if rule.CommandOutputDebug {
					fmt.Println(output)
				}
				continue
			}

			if rule.CommandOutputDebug {
				fmt.Println("command :-")
				fmt.Println(fullCmd)
				fmt.Println(output)
			}
		}

		return 0
	}

	return 0
}

func main() {
	if len(os.Args) < 3 {
		os.Exit(0)
	}

	cfg, err := loadConfig()
	if err != nil {
		fmt.Println("Config error:", err)
		os.Exit(1)
	}

	cmd := os.Args[1 : len(os.Args)-1]
	user := os.Args[len(os.Args)-1]

	os.Exit(processCommand(cmd, user, cfg))
}

func loadConfig() (*Config, error) {
	data, err := os.ReadFile(CONFIG_PATH)
	if err != nil {
		return nil, err
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}

	for i := range cfg.Rules {
		applyRuleDefaults(&cfg.Rules[i])
	}

	return &cfg, nil
}