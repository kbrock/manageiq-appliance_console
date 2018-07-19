require 'pg'
require 'English'
require 'util/postgres_admin'

module ManageIQ
module ApplianceConsole
  class DatabaseReplication
    include ManageIQ::ApplianceConsole::Logging

    REPMGR_CONFIG     = '/etc/repmgr.conf'.freeze
    REPMGR_LOG        = '/var/log/repmgr/repmgrd.log'.freeze
    PGPASS_FILE       = '/var/lib/pgsql/.pgpass'.freeze
    NETWORK_INTERFACE = 'eth0'.freeze

    attr_accessor :node_number, :database_name, :database_user,
                  :database_password, :primary_host

    def ask_for_unique_cluster_node_number
      self.node_number = ask_for_integer("number uniquely identifying this node in the replication cluster")
    end

    def ask_for_database_credentials
      ask_for_cluster_database_credentials
      self.primary_host = ask_for_ip_or_hostname("primary database hostname or IP address", primary_host)
    end

    def confirm
      clear_screen
      say(<<-EOL)
Replication Server Configuration

        Cluster Node Number:        #{node_number}
        Cluster Database Name:      #{database_name}
        Cluster Database User:      #{database_user}
        Cluster Database Password:  "********"
        Cluster Primary Host:       #{primary_host}
        EOL
    end

    def repmgr_configured?
      File.exist?(REPMGR_CONFIG)
    end

    def confirm_reconfiguration
      say("Warning: File #{REPMGR_CONFIG} exists. Replication is already configured")
      logger.warn("Warning: File #{REPMGR_CONFIG} exists. Replication is already configured")
      agree("Continue with configuration? (Y/N): ")
    end

    def create_config_file(host)
      File.write(REPMGR_CONFIG, config_file_contents(host))
      true
    end

    def config_file_contents(host)
      service_name = PostgresAdmin.service_name
      <<-EOS.strip_heredoc
        node_id=#{node_number}
        node_name=#{host}
        conninfo='host=#{host} user=#{database_user} dbname=#{database_name}'
        use_replication_slots=1
        pg_basebackup_options='--xlog-method=stream'
        failover=automatic
        promote_command='repmgr standby promote -f #{REPMGR_CONFIG} --log-to-file'
        follow_command='repmgr standby follow -f #{REPMGR_CONFIG} --log-to-file --upstream-node-id=%n'
        log_file=#{REPMGR_LOG}
        service_start_command='sudo systemctl start #{service_name}'
        service_stop_command='sudo systemctl stop #{service_name}'
        service_restart_command='sudo systemctl restart #{service_name}'
        service_reload_command='sudo systemctl reload #{service_name}'
        data_directory='#{PostgresAdmin.data_directory}'
      EOS
    end

    def write_pgpass_file
      File.open(PGPASS_FILE, "w") do |f|
        f.write("*:*:#{database_name}:#{database_user}:#{database_password}\n")
        f.write("*:*:replication:#{database_user}:#{database_password}\n")
      end

      FileUtils.chmod(0600, PGPASS_FILE)
      FileUtils.chown("postgres", "postgres", PGPASS_FILE)
      true
    end

    private

    def ask_for_cluster_database_credentials
      self.database_name = just_ask("cluster database name", database_name)
      self.database_user = just_ask("cluster database username", database_user)

      count = 0
      loop do
        count += 1
        password1 = ask_for_password("cluster database password", database_password)
        # if they took the default, just bail
        break if password1 == database_password
        password2 = ask_for_password("cluster database password")
        if password1 == password2
          self.database_password = password1
          break
        elsif count > 1 # only reprompt password once
          raise RuntimeError, "passwords did not match"
        else
          say("\nThe passwords did not match, please try again")
        end
      end
    end

    def run_repmgr_command(cmd, params = {})
      pid = fork do
        Process::UID.change_privilege(Process::UID.from_name("postgres"))
        begin
          res = AwesomeSpawn.run!(cmd, :params => params, :env => {"PGPASSWORD" => database_password})
          say(res.output)
        rescue AwesomeSpawn::CommandResultError => e
          say(e.result.output)
          say(e.result.error)
          say("")
          say("Failed to configure replication server")
          raise
        end
      end

      Process.wait(pid)
      $CHILD_STATUS.success?
    end

    def primary_connection_hash
      {
        :dbname   => database_name,
        :host     => primary_host,
        :user     => database_user,
        :password => database_password
      }
    end
  end # class DatabaseReplication
end # module ApplianceConsole
end
