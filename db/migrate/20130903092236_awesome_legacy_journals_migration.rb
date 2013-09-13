#-- copyright
# OpenProject is a project management system.
#
# Copyright (C) 2012-2013 the OpenProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

class AwesomeLegacyJournalsMigration < ActiveRecord::Migration


  class UnsupportedWikiContentJournalCompressionError < ::StandardError
  end

  class WikiContentJournalVersionError < ::StandardError
  end

  class AmbiguousJournalsError < ::StandardError
  end

  class AmbiguousAttachableJournalError < AmbiguousJournalsError
  end

  class InvalidAttachableJournalError < ::StandardError
  end

  class AmbiguousCustomizableJournalError < AmbiguousJournalsError
  end

  class IncompleteJournalsError < ::StandardError
  end


  def up
    check_assumptions

    legacy_journals = fetch_legacy_journals

    puts "Migrating #{legacy_journals.count} legacy journals."

    legacy_journals.each_with_index do |legacy_journal, count|

      type = legacy_journal["type"]

      migrator = get_migrator(type)

      if migrator.nil?
        ignored[type] += 1

        next
      end

      migrator.migrate(legacy_journal)

      if count > 0 && (count % 1000 == 0)
        puts "#{count} journals migrated"
      end
    end

    ignored.each do |type, amount|
      puts "#{type} was ignored #{amount} times"
    end
  end

  def down
  end

  private


  def ignored
    @ignored ||= Hash.new do |k, v|
      0
    end
  end

  def get_migrator(type)
    @migrators ||= begin

      {
        "AttachmentJournal" => attachment_migrator,
        "ChangesetJournal" => changesets_migrator,
        "NewsJournal" => news_migrator,
        "MessageJournal" => message_migrator,
        "WorkPackageJournal" => work_package_migrator,
        "IssueJournal" => work_package_migrator,
        "Timelines_PlanningElementJournal" => work_package_migrator,
        "TimeEntryJournal" => time_entry_migrator,
        "WikiContentJournal" => wiki_content_migrator
      }
    end

    @migrators[type]
  end

  def attachment_migrator
    LegacyJournalMigrator.new("AttachmentJournal", "attachment_journals") do

      def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id)

        rewrite_issue_container_to_work_package(to_insert)

      end

      def rewrite_issue_container_to_work_package(to_insert)
        if to_insert['container_type'].last == 'Issue'

          to_insert['container_type'][-1] = 'WorkPackage'

        end
      end
    end
  end

  def changesets_migrator
    LegacyJournalMigrator.new("ChangesetJournal", "changeset_journals")
  end

  def news_migrator
    LegacyJournalMigrator.new("NewsJournal", "news_journals")
  end

  def message_migrator
    LegacyJournalMigrator.new("MessageJournal", "message_journals") do
      extend MigratorConcern::Attachable

      def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id)

        migrate_attachments(to_insert, legacy_journal, journal_id)

      end
    end
  end

  def work_package_migrator
    LegacyJournalMigrator.new "WorkPackageJournal", "work_package_journals" do
      extend MigratorConcern::Attachable
      extend MigratorConcern::Customizable

      def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id)

        migrate_attachments(to_insert, legacy_journal, journal_id)

        migrate_custom_values(to_insert, legacy_journal, journal_id)

      end
    end
  end

  def time_entry_migrator
    LegacyJournalMigrator.new("TimeEntryJournal", "time_entry_journals") do
      extend MigratorConcern::Customizable

      def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id)

        migrate_custom_values(to_insert, legacy_journal, journal_id)

      end
    end
  end

  def wiki_content_migrator

    LegacyJournalMigrator.new("WikiContentJournal", "wiki_content_journals") do

      def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id)

        # remove once lock_version is no longer a column in the wiki_content_journales table
        if !to_insert.has_key?("lock_version")

          if !legacy_journal.has_key?("version")
            raise WikiContentJournalVersionError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              There is a wiki content without a version.
              The DB requires a version to be set
              #{legacy_journal},
              #{to_insert}
            MESSAGE

          end

          # as the old journals used the format [old_value, new_value] we have to fake it here
          to_insert["lock_version"] = [nil,legacy_journal["version"]]
        end

        if to_insert.has_key?("data")

          # Why is that checked but than the compression is not used in any way to read the data
          if !to_insert.has_key?("compression")

            raise UnsupportedWikiContentJournalCompressionError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              There is a WikiContent journal that contains data in an
              unsupported compression: #{compression}
            MESSAGE

          end

          # as the old journals used the format [old_value, new_value] we have to fake it here
          to_insert["text"] = [nil, to_insert.delete("data")]
        end
      end

    end
  end

  module MigratorConcern

    module Attachable
      def migrate_attachments(to_insert, legacy_journal, journal_id)
        attachments = to_insert.keys.select { |d| d =~ attachment_key_regexp }

        attachments.each do |key|

          attachment_id = attachment_key_regexp.match(key)[1]

          # if an attachment was added the value contains something like:
          # [nil, "blubs.png"]
          # if it was removed the value is something like
          # ["blubs.png", nil]
          removed_filename, added_filename = *to_insert[key]

          if added_filename && !removed_filename
            # The attachment was added

            attachable = ActiveRecord::Base.connection.select_all <<-SQL
              SELECT *
              FROM #{attachable_table_name} AS a
              WHERE a.journal_id = #{quote_value(journal_id)} AND a.attachment_id = #{attachment_id};
            SQL

            if attachable.size > 1

              raise AmbiguousAttachableJournalError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
                It appears there are ambiguous attachable journal data.
                Please make sure attachable journal data are consistent and
                that the unique constraint on journal_id and attachment_id
                is met.
              MESSAGE

            elsif attachable.size == 0

              db_execute <<-SQL
                INSERT INTO #{attachable_table_name}(journal_id, attachment_id, filename)
                VALUES (#{quote_value(journal_id)}, #{quote_value(attachment_id)}, #{quote_value(added_filename)});
              SQL
            end

          elsif removed_filename && !added_filename
            # The attachment was removed
            # we need to make certain that no subsequent journal adds an attachable_journal
            # for this attachment

            to_insert.delete_if { |k, v| k =~ /attachments_?#{attachment_id}/ }

          else
            raise InvalidAttachableJournalError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              There is a journal entry for an attachment but neither the old nor the new value contains anything:
              #{to_insert}
              #{legacy_journal}
            MESSAGE
          end

        end

      end

      def attachable_table_name
        quoted_table_name("attachable_journals")
      end

      def attachment_key_regexp
        # Attachment journal entries can be written in two ways:
        # attachments123 if the attachment was added
        # attachments_123 if the attachment was removed
        #
        @attachment_key_regexp ||= /attachments_?(\d+)$/
      end
    end

    module Customizable
      def migrate_custom_values(to_insert, legacy_journal, journal_id)
        keys = to_insert.keys
        values = to_insert.values

        custom_values = keys.select { |d| d =~ /custom_values.*/ }
        custom_values.each do |k|

          custom_field_id = k.split("_values").last.to_i
          value = values[keys.index k].last

          customizable = db_select_all <<-SQL
            SELECT *
            FROM #{customizable_table_name} AS a
            WHERE a.journal_id = #{quote_value(journal_id)} AND a.custom_field_id = #{custom_field_id};
          SQL

          if customizable.size > 1

            raise AmbiguousCustomizableJournalError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              It appears there are ambiguous customizable journal
              data. Please make sure customizable journal data are
              consistent and that the unique constraint on journal_id and
              custom_field_id is met.
            MESSAGE

          elsif customizable.size == 0

            db_execute <<-SQL
              INSERT INTO #{customizable_table_name}(journal_id, custom_field_id, value)
              VALUES (#{quote_value(journal_id)}, #{quote_value(custom_field_id)}, #{quote_value(value)});
            SQL
          end

        end
      end

      def customizable_table_name
        quoted_table_name("customizable_journals")
      end
    end
  end


  # fetches legacy journals. might me empty.
  def fetch_legacy_journals

    attachments_and_changesets = ActiveRecord::Base.connection.select_all <<-SQL
      SELECT *
      FROM #{quoted_legacy_journals_table_name} AS j
      WHERE (j.activity_type = #{quote_value("attachments")})
        OR (j.activity_type = #{quote_value("custom_fields")})
      ORDER BY j.journaled_id, j.type, j.version;
    SQL

    remainder = ActiveRecord::Base.connection.select_all <<-SQL
      SELECT *
      FROM #{quoted_legacy_journals_table_name} AS j
      WHERE NOT ((j.activity_type = #{quote_value("attachments")})
        OR (j.activity_type = #{quote_value("custom_fields")}))
      ORDER BY j.journaled_id, j.type, j.version;
    SQL

    attachments_and_changesets + remainder
  end

  def quoted_legacy_journals_table_name
    @quoted_legacy_journals_table_name ||= quote_table_name 'legacy_journals'
  end

  def check_assumptions

    # SQL finds all those journals whose has more or less predecessors than
    # it's version would require. Ignores the first journal.
    # e.g. a journal with version 5 would have to have 5 predecessors
    invalid_journals = ActiveRecord::Base.connection.select_values <<-SQL
      SELECT DISTINCT tmp.id
      FROM (
        SELECT
          a.id AS id,
          a.journaled_id,
          a.type,
          a.version AS version,
          count(b.id) AS count
        FROM
          #{quoted_legacy_journals_table_name} AS a
        LEFT JOIN
          #{quoted_legacy_journals_table_name} AS b
          ON a.version >= b.version
            AND a.journaled_id = b.journaled_id
            AND a.type = b.type
        WHERE a.version > 1
        GROUP BY
          a.id,
          a.journaled_id,
          a.type,
          a.version
      ) AS tmp
      WHERE
        NOT (tmp.version = tmp.count);
    SQL

    unless invalid_journals.empty?

      raise IncompleteJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
        It appears there are incomplete journals. Please make sure
        journals are consistent and that for every journal, there is an
        initial journal containing all attribute values at the time of
        creation. The offending journal ids are: #{invalid_journals}
      MESSAGE
    end
  end

  module DbWorker
    def quote_value(name)
      ActiveRecord::Base.connection.quote name
    end

    def quoted_table_name(name)
      ActiveRecord::Base.connection.quote_table_name name
    end

    def db_columns(table_name)
      ActiveRecord::Base.connection.columns table_name
    end

    def db_select_all(statement)
      ActiveRecord::Base.connection.select_all statement
    end

    def db_execute(statement)
      ActiveRecord::Base.connection.execute statement
    end
  end

  include DbWorker

  class LegacyJournalMigrator
    include DbWorker

    attr_accessor :table_name,
                  :type,
                  :journable_class

    def initialize(type, table_name, &block)
      self.table_name = table_name
      self.type = type

      instance_eval &block if block_given?

      if table_name.nil? || type.nil?
        raise ArgumentError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
        table_name and type have to be provided. Either as parameters or set within the block.
        MESSAGE
      end

      self.journable_class = self.type.gsub(/Journal$/, "")
    end

    def migrate(legacy_journal)
      journal = set_journal(legacy_journal)
      journal_id = journal["id"]

      set_journal_data(journal_id, legacy_journal)
    end

    protected

    def combine_journal(journaled_id, legacy_journal)
      # compute the combined journal from current and all previous changesets.
      combined_journal = legacy_journal["changed_data"]
      if previous.journaled_id == journaled_id
        combined_journal = previous.journal.merge(combined_journal)
      end

      # remember the combined journal as the previous one for the next iteration.
      previous.set(combined_journal, journaled_id)

      combined_journal
    end

    def previous
      @previous ||= PreviousState.new({}, 0)
    end

    # here to be overwritten by instances
    def migrate_key_value_pairs!(to_insert, legacy_journal, journal_id) end

    # fetches specific journal data row. might be empty.
    def fetch_existing_data_journal(journal_id)
      ActiveRecord::Base.connection.select_all <<-SQL
        SELECT *
        FROM #{journal_table_name} AS d
        WHERE d.journal_id = #{quote_value(journal_id)};
      SQL
    end

    # gets a journal row, and makes sure it has a valid id in the database.
    # if the journal does not exist, it creates it
    def set_journal(legacy_journal)

      journal = fetch_journal(legacy_journal)

      if journal.size > 1

        raise AmbiguousJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
          It appears there are ambiguous journals. Please make sure
          journals are consistent and that the unique constraint on id,
          type and version is met.
        MESSAGE

      elsif journal.size == 0

        journal = create_journal(legacy_journal)

      end

      journal.first
    end

    # fetches specific journal row. might be empty.
    def fetch_journal(legacy_journal)
      id, version = legacy_journal["journaled_id"], legacy_journal["version"]

      db_select_all <<-SQL
        SELECT *
        FROM #{quoted_journals_table_name} AS j
        WHERE j.journable_id = #{quote_value(id)}
          AND j.journable_type = #{quote_value(journable_class)}
          AND j.version = #{quote_value(version)};
      SQL
    end

    # creates a valid journal.
    # But might be not what is desired as an end result, yet.  It is e.g.
    # created with created_at set to now. This will need to be set to an actual
    # date
    def create_journal(legacy_journal)

      db_execute <<-SQL
        INSERT INTO #{quoted_journals_table_name} (
          id,
          journable_id,
          version,
          user_id,
          notes,
          activity_type,
          created_at,
          journable_type
        )
        VALUES (
          #{quote_value(legacy_journal["id"])},
          #{quote_value(legacy_journal["journaled_id"])},
          #{quote_value(legacy_journal["version"])},
          #{quote_value(legacy_journal["user_id"])},
          #{quote_value(legacy_journal["notes"])},
          #{quote_value(legacy_journal["activity_type"])},
          #{quote_value(legacy_journal["created_at"])},
          #{quote_value(journable_class)}
        );
      SQL

      fetch_journal(legacy_journal)
    end

    def set_journal_data(journal_id, legacy_journal)

      deserialize_journal(legacy_journal)
      journaled_id = legacy_journal["journaled_id"]

      combined_journal = combine_journal(journaled_id, legacy_journal)
      migrate_key_value_pairs!(combined_journal, legacy_journal, journal_id)

      to_insert = insertable_data_journal(combined_journal)

      existing_data_journal = fetch_existing_data_journal(journal_id)

      if existing_data_journal.size > 1

        raise AmbiguousJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
          It appears there are ambiguous journal data. Please make sure
          journal data are consistent and that the unique constraint on
          journal_id is met.
        MESSAGE

      elsif existing_data_journal.size == 0

        existing_data_journal = create_data_journal(journal_id, to_insert)

      end

      existing_data_journal = existing_data_journal.first

      update_data_journal(existing_data_journal["id"], to_insert)
    end

    def create_data_journal(journal_id, to_insert)
      keys = to_insert.keys
      values = to_insert.values

      db_execute <<-SQL
        INSERT INTO #{journal_table_name} (journal_id#{", " + keys.join(", ") unless keys.empty? })
        VALUES (#{quote_value(journal_id)}#{", " + values.map{|d| quote_value(d)}.join(", ") unless values.empty?});
      SQL

      fetch_existing_data_journal(journal_id)
    end

    def update_data_journal(id, to_insert)
      db_execute <<-SQL unless to_insert.empty?
        UPDATE #{journal_table_name}
           SET #{(to_insert.each.map { |key,value| "#{key} = #{quote_value(value)}"}).join(", ") }
         WHERE id = #{id};
      SQL

    end

    def deserialize_journal(journal)
      integerize_ids(journal)

      journal["changed_data"] = YAML.load(journal["changed_data"])
    end

    def insertable_data_journal(journal)
      journal.inject({}) do |mem, (key, value)|
        current_key = map_key(key)

        if column_names.include?(current_key)
          # The old journal's values attribute was structured like
          # [old_value, new_value]
          # We only need the new_value
          mem[current_key] = value.last
        end

        mem
      end
    end

    def map_key(key)
      case key
      when "issue_id"
        "work_package_id"
      when "tracker_id"
        "type_id"
      when "end_date"
        "due_date"
      else
        key
      end
    end

    def integerize_ids(journal)
      # turn id fields into integers.
      ["id", "journaled_id", "user_id", "version"].each do |f|
        journal[f] = journal[f].to_i
      end
    end

    def journal_table_name
      quoted_table_name(table_name)
    end

    def quoted_journals_table_name
      @quoted_journals_table_name ||= quoted_table_name 'journals'
    end

    def column_names
      @column_names ||= db_columns(table_name).map(&:name)
    end
  end

  class PreviousState < Struct.new(:journal, :journaled_id)
    def set(journal, journaled_id)
      self.journal = journal
      self.journaled_id = journaled_id
    end
  end

end
