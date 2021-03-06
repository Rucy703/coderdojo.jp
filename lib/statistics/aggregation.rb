module Statistics
  class Aggregation
    def initialize(args)
      @mode = detect_mode(args[:from])
      @from = aggregation_from(args[:from])
      @to = aggregation_to(args[:to])
      @dojos = fetch_dojos
    end

    def run
      "Statistics::Aggregation::#{@mode.camelize}".constantize.new(@dojos, @from, @to).run
    end

    private

    def detect_mode(from)
      if from
        if from.length == 4 || from.length == 6
          'monthly'
        else
          'weekly'
        end
      else
        'weekly'
      end
    end

    def aggregation_from(from)
      if from
        if from.length == 4
          date_from(from).beginning_of_year
        elsif from.length == 6
          date_from(from).beginning_of_month
        else
          date_from(from).beginning_of_week
        end
      else
        Time.current.prev_week.beginning_of_week
      end
    end

    def aggregation_to(to)
      if to
        if to.length == 4
          date_from(to).end_of_year
        elsif to.length == 6
          date_from(to).end_of_month
        else
          date_from(to).end_of_week
        end
      else
        Time.current.prev_week.end_of_week
      end
    end

    def date_from(str)
      formats = %w(%Y%m%d %Y/%m/%d %Y-%m-%d %Y%m %Y/%m %Y-%m)
      d = formats.map { |fmt|
        begin
          Time.zone.strptime(str, fmt)
        rescue ArgumentError
          Time.zone.local(str) if str.length == 4
        end
      }.compact.first

      raise ArgumentError, "Invalid format: `#{str}`, allow format is #{formats.push('%Y').join(' or ')}" if d.nil?

      d
    end

    def fetch_dojos
      {
        externals: find_dojos_by(DojoEventService::EXTERNAL_SERVICES),
        internals: find_dojos_by(DojoEventService::INTERNAL_SERVICES)
      }
    end

    def find_dojos_by(services)
      services.each.with_object({}) do |name, hash|
        hash[name] = Dojo.eager_load(:dojo_event_services).where(dojo_event_services: { name: name }).to_a
      end
    end

    class Base
      def initialize(dojos, from, to)
        @externals = dojos[:externals]
        @internals = dojos[:internals]
        @list = build_list(from, to)
        @from = from
        @to = to
      end

      def run
        with_notifying do
          delete_event_histories
          execute
          execute_once
        end
      end

      private

      def with_notifying
        yield
        Notifier.notify_success(date_format(@from), date_format(@to))
      rescue => e
        Notifier.notify_failure(date_format(@from), date_format(@to), e)
      end

      def delete_event_histories
        (@externals.keys + @internals.keys).each do |kind|
          "Statistics::Tasks::#{kind.to_s.camelize}".constantize.delete_event_histories(@from..@to)
        end
      end

      def execute
        raise NotImplementedError.new("You must implement #{self.class}##{__method__}")
      end

      def execute_once
        @internals.each do |kind, list|
          "Statistics::Tasks::#{kind.to_s.camelize}".constantize.new(list, nil, nil).run
        end
      end

      def build_list(_from, _to)
        raise NotImplementedError.new("You must implement #{self.class}##{__method__}")
      end

      def date_format(_date)
        raise NotImplementedError.new("You must implement #{self.class}##{__method__}")
      end
    end

    class Weekly < Base
      private

      def execute
        @list.each do |date|
          puts "Aggregate for #{date_format(date)}~#{date_format(date.end_of_week)}"

          @externals.each do |kind, list|
            "Statistics::Tasks::#{kind.to_s.camelize}".constantize.new(list, date, true).run
          end
        end
      end

      def build_list(from, to)
        DateTimeUtil.every_week_array(from, to)
      end

      def date_format(date)
        date.strftime('%Y/%m/%d')
      end
    end

    class Monthly < Base
      private

      def execute
        @list.each do |date|
          puts "Aggregate for #{date_format(date)}"

          @externals.each do |kind, list|
            "Statistics::Tasks::#{kind.to_s.camelize}".constantize.new(list, date, false).run
          end
        end
      end

      def build_list(from, to)
        DateTimeUtil.every_month_array(from, to)
      end

      def date_format(date)
        date.strftime('%Y/%m')
      end
    end

    class Notifier
      class << self
        def notify_success(from, to)
          notify("#{from}~#{to}のイベント履歴の集計を行いました")
        end

        def notify_failure(from, to, exception)
          notify("#{from}~#{to}のイベント履歴の集計でエラーが発生しました\n#{exception.message}\n#{exception.backtrace.join("\n")}")
        end

        private

        def idobata_hook_url
          return @idobata_hook_url if defined?(@idobata_hook_url)
          @idobata_hook_url = ENV['IDOBATA_HOOK_URL']
        end

        def notifierable?
          idobata_hook_url.present?
        end

        def notify(msg)
          $stdout.puts msg
          puts `curl --data-urlencode "source=#{msg}" -s #{idobata_hook_url} -o /dev/null -w "idobata: %{http_code}"` if notifierable?
        end
      end
    end
  end
end
