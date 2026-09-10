package main

import "time"

// Weekdays use ISO numbering. Overnight intervals belong to their start day.
// Missing policies retain legacy admission; malformed policies fail closed.
type managerDispatchWindow struct {
	Mode               string                    `json:"mode"`
	TimeZoneIdentifier string                    `json:"timeZoneIdentifier"`
	Intervals          []managerDispatchInterval `json:"intervals"`
}

type managerDispatchInterval struct {
	StartMinute *int  `json:"startMinute"`
	EndMinute   *int  `json:"endMinute"`
	AllDays     *bool `json:"allDays"`
	Weekdays    []int `json:"weekdays"`
	AllDay      *bool `json:"allDay"`
}

func (policy *managerDispatchWindow) allows(now time.Time) bool {
	if policy == nil {
		return true
	}
	if policy.Mode != "unrestricted" && policy.Mode != "onlyWithin" && policy.Mode != "exceptWithin" {
		return false
	}
	if policy.TimeZoneIdentifier == "" || policy.TimeZoneIdentifier == "Local" {
		return false
	}
	zone, err := time.LoadLocation(policy.TimeZoneIdentifier)
	if err != nil || policy.Intervals == nil || len(policy.Intervals) > 32 {
		return false
	}
	local := now.In(zone)
	weekday := int(local.Weekday())
	if weekday == 0 {
		weekday = 7
	}
	previous := weekday - 1
	if previous == 0 {
		previous = 7
	}
	minute := local.Hour()*60 + local.Minute()
	matched := false
	for _, interval := range policy.Intervals {
		if interval.StartMinute == nil || interval.EndMinute == nil || interval.AllDays == nil || interval.AllDay == nil || interval.Weekdays == nil {
			return false
		}
		start, end := *interval.StartMinute, *interval.EndMinute
		allDays, allDay := *interval.AllDays, *interval.AllDay
		if start < 0 || start >= 1440 || end < 0 || end >= 1440 || (!allDay && start == end) || (!allDays && len(interval.Weekdays) == 0) {
			return false
		}
		today, yesterday := allDays, allDays
		for _, day := range interval.Weekdays {
			if day < 1 || day > 7 {
				return false
			}
			today = today || day == weekday
			yesterday = yesterday || day == previous
		}
		if allDay {
			matched = matched || today
		} else if start < end {
			matched = matched || today && minute >= start && minute < end
		} else {
			matched = matched || today && minute >= start || yesterday && minute < end
		}
	}
	if policy.Mode == "unrestricted" {
		return true
	}
	if policy.Mode == "onlyWithin" {
		return matched
	}
	return !matched
}
