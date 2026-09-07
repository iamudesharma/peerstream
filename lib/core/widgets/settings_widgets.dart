import 'package:flutter/material.dart';

import '../design_tokens.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.title,
    required this.children,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: DesignTokens.textTertiary,
                      ),
                ),
              ],
            ],
          ),
        ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: icon != null
          ? Icon(
              icon,
              color: enabled
                  ? DesignTokens.textSecondary
                  : DesignTokens.textTertiary,
            )
          : null,
      title: Text(
        title,
        style: TextStyle(
          color: enabled
              ? DesignTokens.textPrimary
              : DesignTokens.textTertiary,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
      onTap: enabled ? onTap : null,
      enabled: enabled,
    );
  }
}

class SettingsToggle extends StatelessWidget {
  const SettingsToggle({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: icon != null
          ? Icon(
              icon,
              color: enabled
                  ? DesignTokens.textSecondary
                  : DesignTokens.textTertiary,
            )
          : null,
      title: Text(
        title,
        style: TextStyle(
          color: enabled
              ? DesignTokens.textPrimary
              : DesignTokens.textTertiary,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}

class SettingsSelect<T> extends StatelessWidget {
  const SettingsSelect({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
    this.icon,
    super.key,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<SelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final current = options.firstWhere(
      (o) => o.value == value,
      orElse: options.isNotEmpty ? () => options.first : () => options.first,
    );
    return ListTile(
      leading: icon != null ? Icon(icon) : null,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: PopupMenuButton<T>(
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (context) => options
            .map(
              (option) => PopupMenuItem<T>(
                value: option.value,
                child: Text(
                  option.label,
                  style: option.value == value
                      ? const TextStyle(
                          color: DesignTokens.accent,
                          fontWeight: FontWeight.w600,
                        )
                      : null,
                ),
              ),
            )
            .toList(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current.label,
              style: const TextStyle(color: DesignTokens.textSecondary),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

class SelectOption<T> {
  const SelectOption({required this.value, required this.label});
  final T value;
  final String label;
}

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.destructive = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final IconData? icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? DesignTokens.danger : DesignTokens.textPrimary;
    return ListTile(
      leading: icon != null
          ? Icon(icon, color: destructive ? DesignTokens.danger : null)
          : null,
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(
                color: destructive
                    ? DesignTokens.danger.withValues(alpha: 0.7)
                    : DesignTokens.textSecondary,
              ),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right,
        color: DesignTokens.textTertiary,
      ),
      onTap: onTap,
    );
  }
}

class SettingsInfo extends StatelessWidget {
  const SettingsInfo({
    required this.title,
    required this.value,
    this.icon,
    super.key,
  });

  final String title;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: icon != null ? Icon(icon) : null,
      title: Text(title),
      trailing: Text(
        value,
        style: const TextStyle(color: DesignTokens.textSecondary),
      ),
    );
  }
}

class SettingsTextField extends StatelessWidget {
  const SettingsTextField({
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.keyboardType,
    this.errorText,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final TextInputType? keyboardType;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon != null ? Icon(icon) : null,
          errorText: errorText,
        ),
      ),
    );
  }
}
