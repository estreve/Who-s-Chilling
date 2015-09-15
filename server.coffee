Db = require 'db'
Event = require 'event'
Plugin = require 'plugin'
{tr} = require 'i18n'

exports.onConfig = exports.onInstall = (config) !->
	if config?
		Db.shared.set 'deadline', config.deadline
		setTimers()

		if config.defaults
			offset = (new Date).getTimezoneOffset()
			today = 0|((Plugin.time()-offset*60)/86400)
			log 'defaults saving'

			# check which days have changed, add current day as starting point in 'd'
			def = JSON.parse(config.defaults)
			for userId, days of def
				log 'checking'
				for dayNr, day of days when day.eat isnt (oldEat = Db.shared.get('defaults', userId, dayNr, 'eat'))
					# default changed, write new 'd' (or remove default)
					if day.eat?
						Db.shared.set 'defaults', userId, dayNr,
							d: today
							eat: day.eat
					else
						Db.shared.remove 'defaults', userId, dayNr

					# and write status for next two weeks
					endDay = today+14
					for nr in [today..endDay]
						continue if require('util.js').getUTCDay(nr) isnt +dayNr
						eat = Db.shared.get 'days', nr, 'eat', userId
						if !eat? or eat>500
							Db.shared.set 'days', nr, 'eat', userId, (if day.eat? then (+day.eat)+1000 else null)

				# this is a way to remove a user from the default settings: after leaving the happening
				# set all default statuses for the user to 'unknown'
				if objEmpty(Db.shared.get 'defaults', userId)
					Db.shared.remove 'defaults', userId

exports.onUpgrade = !->
	setTimers()

objEmpty = (obj) ->
	return false for x of obj
	true

setTimers = (extraTime=0) !->
	Timer = require 'timer'
	Timer.cancel()

	deadline = Db.shared.get 'deadline'
	return unless deadline?

	time = Plugin.time()
	dayStart = Math.floor(time/86400)*86400
	for type,offset of {remind: -1800, deadline: 0, defaults: 0}
		next = dayStart + deadline + offset
		next += 86400 if next <= time+extraTime
		Timer.set (next-time)*1000, type

exports.defaults = !->
	# write defaults for the day over two weeks (take one day before and after for margin)
	gud = require('util.js').getUTCDay
	day = 0|(Plugin.time()/86400)
	writeDays = [day+13, day+14, day+15]
	utcDays = [gud(writeDays[0]), gud(writeDays[1]), gud(writeDays[2])]
	def = Db.shared.get('defaults')
	for userId, days of def
		for dayNr, day of days
			idx = utcDays.indexOf(+dayNr)
			if idx>=0
				eat = Db.shared.get 'days', writeDays[idx], 'eat', userId
				if !eat? or eat>500
					Db.shared.set 'days', writeDays[idx], 'eat', userId, (+day.eat)+1000


exports.remind = !->
	day = 0|(Plugin.time()/86400)
	eat = Db.shared.get('days',day,'eat') || {}
	remind = false
	for userId, value of eat when value>0 or value>1000
		# at least one person is hungry today, remind others
		remind = true
		break

	if remind
		include = []
		for userId in Plugin.userIds() when !eat[userId]? or eat[userId] is ''
			include.push userId
		if include.length
			Event.create
				text: tr 'Are you hungry/cooking? Deadline in 30m!'
				unit: tr 'eat?'
				for: include
	setTimers 300

exports.deadline = !->
	day = 0|(Plugin.time()/86400)
	cookId = Db.shared.get('days',day,'cook')
	eaters = []
	cnt = 0
	for userId,value of Db.shared.get('days',day,'eat')
		if value>500 # convert default to 'hard' values
			Db.shared.set('days', day, 'eat', userId, value%1000)
		if value%1000 # count people that are hungry
			cnt += Math.abs(value%1000)
			eaters.push userId
	if eaters.length==1
		Event.create
			text: tr 'Nobody else seems to be hungry. Too bad!'
			unit: tr 'msg'
			for: eaters
	else if eaters.length>1
		if cookId
			Event.create
				text: tr "Hey chef, dinner for #{cnt} please!"
				unit: tr 'msg'
				for: [cookId]
		else
			Event.create
				text: tr "No chef yet. :( Will you feed the #{cnt} hungry?"
				unit: tr 'eat?'
				for: eaters
	setTimers 300


# exported functions prefixed with 'client_' are callable by our client code using `require('plugin').rpc`
exports.client_eat = (day, newState, userId) !->
	info = Db.shared.createRef 'days', day

	userId = (0|userId) || Plugin.userId()
	oldCookId = info.get('cook')
	cookId = if newState<0 then (if oldCookId then oldCookId else userId) else (if oldCookId==userId then null else oldCookId)

	info.set 'cook', cookId
	info.set 'eat', userId, if newState<0 then -newState else (if !newState? or newState is '' then '' else +newState)

	if cookId != oldCookId
		Db.personal(oldCookId).set('open',day,null) if oldCookId
		Db.personal(cookId).set('open',day,true) if cookId and !info.get('cost')?

	complaints = ""

	if userId != Plugin.userId()
		complaints += " "+tr("for %1",Plugin.userName(userId))

	deadline = Db.shared.get 'deadline'
	if deadline?
		if Plugin.time() > day*86400+deadline+(if newState<0 then 3600 else 0) # extra hour to become cook
			complaints += " "+tr("after the deadline")

	if complaints
		logComment day, 'stat'+userId, -> tr("changed status")+complaints


logComment = (day,topic,cb) !->
	comment =
		t: 0|Plugin.time()
		u: Plugin.userId()
		s: topic
	comments = Db.shared.createRef("comments",day)
	if max = 0|comments.get("max")
		last = comments.get(max)
		if last.t > comment.t-120 and last.u == comment.u and last.s == comment.s
			recycle = true
	unless recycle
		comments.set "max", ++max
	if comment.c = cb(comment, if recycle then last else null)
		comments.set max, comment


exports.client_cost = (day, value) !->
	info = Db.shared.createRef 'days', day
	value = if value==null then null else parseFloat(value)
	oldValue = info.get('cost')
	info.set 'cost', value
	cookId = info.get('cook')
	Db.personal(cookId).set('open',day,if value==null then true else null) if cookId

	fc = require('util.js').formatCurrency
	logComment day, 'cost', (newC, oldC) ->
		oldValue = oldC._o if oldC
		newC._o = oldValue
		if oldValue?
			tr "changed total cost from %1 to %2",
				fc(oldValue)
				if value? then fc(value) else "??"
		else
			tr "entered total cost: %1", if value? then fc(value) else "??"