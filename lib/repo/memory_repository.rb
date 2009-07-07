require File.join(File.dirname(__FILE__),'/repository')
require "rubygems"
require "ruby-debug"
module Repository

# Implements AbstractRepository for memory repositories
# It implements the following paradigm:
#   1. Repositories are created by using MemoryRepository.create()
#   2. Existing repositories are opened by using either SubversionRepository.open()
#      or SubversionRepository.new()
class MemoryRepository < Repository::AbstractRepository
  
  # class variable which knows of all memory repositories
  #    key (location), value (reference to repo)
  @@repositories = {}
  
  #############################################################
  #   A MemoryRepository instance holds the following variables
  #     - current_revision
  #     - revision_history
  #     - timestamps_revisions
  #############################################################
  
  # Constructor: Connects to an existing Memory
  # repository; Note: A repository has to be created using
  # MemoryRepository.create(), if it is not yet existent
  # Generally: Do not(!) call it with 2 parameters, use MemoryRepository.create() instead!
  def initialize(location, is_create_call=false)
    
    # variables
    @users = []                                 # list of users with read/write permissions
    @current_revision = MemoryRevision.new(0)   # the latest revision (we start from 0)
    @revision_history = []                      # a list (array) of old revisions (i.e. < @current_revision)
    # mapping (hash) of timestamps and revisions
    @timestamps_revisions = {}
    @timestamps_revisions[Time.now._dump.to_s] = @current_revision   # push first timestamp-revision mapping
    
    # hack(ish) functionality
    if !is_create_call
      begin
        super(location) # dummy super() call to be ruby conformant (in fact, does nothing but raising an exception) 
      rescue NotImplementedError; end
      if !self.class.repository_exists?(location)
        raise "Could not open repository at location #{location}"
      end
      return @@repositories[location] # return reference in question
    else
      if MemoryRepository.repository_exists?(location)
        raise RepositoryCollision.new("There is already a repository at #{location}")
      end
      @@repositories[location] = self             # push new MemoryRepository onto repository list
    end
    
  end
  
  # Checks if a memory repository exists at 'path'
  def self.repository_exists?(path)
    @@repositories.each do |location, repo|
      if path == location
        return true
      end
    end
    return false
  end
  
  def self.open(location)
    #return @@repositories[location]
    return MemoryRepository.new(location)
  end
  
  # Creates memory repository at "virtual" location (they are identifiable by location)
  def self.create(location)
    MemoryRepository.new(location, true) # want to create a repository
    return MemoryRepository.open(location)
  end
  
  # Destroys all repositories
  def self.purge_all()
    @@repositories = {}
  end
  
  # Given either an array of, or a single object of class RevisionFile, 
  # return a stream of data for the user to download as the file(s).
  def stringify_files(files)
    is_array = files.kind_of? Array
    if (!is_array)
      files = [files]  
    end
    files.collect! do |file|   
      if (!file.kind_of? Repository::RevisionFile)
        raise TypeError.new("Expected a Repository::RevisionFile")
      end
      rev = get_revision(file.from_revision)
      content = rev.files_content[file.to_s]
      if content.nil?
        raise FileDoesNotExistConflict.new(File.join(file.path, file.name))
      end
      content # spews out content to be collected (Ruby collect!() magic) :-)
    end
    if (!is_array)
      return files.first
    else
      return files
    end
  end
  alias download_as_string stringify_files
  
  def get_transaction(user_id, comment="")
    if user_id.nil?
      raise "Expected a user_id (Repository.get_transaction(user_id))"
    end
    return Repository::Transaction.new(user_id, comment)
  end  
  
  def commit(transaction)
    jobs = transaction.jobs
    # make a deep copy of current revision
    new_rev = copy_revision(@current_revision)
    new_rev.user_id = transaction.user_id # set commit-user for new revision
    jobs.each do |job|
      case job[:action]
        when :add_path
          begin
            new_rev = make_directory(new_rev, job[:path])
          rescue Repository::Conflict => e
            transaction.add_conflict(e)
          end
        when :add
          begin
            new_rev = add_file(new_rev, job[:path], job[:file_data], job[:mime_type])
          rescue Repository::Conflict => e
            transaction.add_conflict(e)
          end
        when :remove
          begin
            new_rev = remove_file(new_rev, job[:path], job[:expected_revision_number])
          rescue Repository::Conflict => e
            transaction.add_conflict(e)
          end
      end
    end
    
    if transaction.conflicts?
      return false
    end
    
    # everything went fine, so push old revision to history revisions,
    # make new_rev the latest one and create a mapping for timestamped
    # revisions
    @revision_history.push(@current_revision)
    @current_revision = new_rev
    @current_revision.__increment_revision_number() # increment revision number
    @timestamps_revisions[Time.now._dump.to_s] = @current_revision
    
    return true
  end
  
  # Returns the latest revision number (as a RepositoryRevision object)
  def get_latest_revision()
    return @current_revision
  end
    
  # Return a RepositoryRevision for a given rev_num (int)
  def get_revision(rev_num)
    if (@current_revision.revision_number == rev_num)
      return @current_revision
    end
    @revision_history.each do |revision|
      if (revision.revision_number == rev_num)
        return revision
      end
    end
    # revision with the specified revision number does not exist,
    # so raise error
    raise RevisionDoesNotExist
  end
  
  # Return a RepositoryRevision for a given timestamp
  def get_revision_by_timestamp(timestamp)
    if !timestamp.kind_of?(Time)
      raise "Was expecting a timestamp of type Time"
    end
    return get_revision_number_by_timestamp(timestamp)
  end
   
  # Adds user permissions for read/write access to the repository
  def add_user(user_id)
    raise NotImplementedError,  "Repository.add_user: Not yet implemented"
  end
  
  # Removes user permissions for read/write access to the repository
  def remove_user(user_id)
    raise NotImplementedError,  "Repository.remove_user: Not yet implemented"
  end
  
  def get_users
    raise NotImplementedError, "Repository.get_users: Not yet implemented"
  end
  
  private
  
  # Creates a directory as part of the provided revision
  def make_directory(rev, full_path)
    if rev.path_exists?(full_path)
      raise FileExistsConflict # raise conflict if path exists 
    end
    dir = RevisionDirectory.new(rev.revision_number, {
      :name => File.basename(full_path),
      :path => File.dirname(full_path),
      :last_modified_revision => rev.revision_number,
      :changed => true,
      :user_id => rev.user_id
    })
    rev.__add_directory(dir)
    return rev
  end
  
  # Adds a file into the provided revision
  def add_file(rev, full_path, content, mime_type="text/plain")
    if file_exists?(rev, full_path)
      raise FileExistsConflict
    end
    # file does not exist, so add it
    file = RevisionFile.new(rev.revision_number, {
      :name => File.basename(full_path),
      :path => File.dirname(full_path),
      :last_modified_revision => rev.revision_number,
      :changed => true,
      :user_id => rev.user_id
    })
    rev.__add_file(file, content)
    return rev
  end
  
  # Removes a file from the provided revision
  def remove_file(rev, full_path, expected_revision_int)
    if !file_exists?(rev, full_path)
      raise FileDoesNotExistConflict
    end
    act_rev = get_latest_revision()
    if (act_rev.revision_number != expected_revision_int)
      raise Repository::FileOutOfSyncConflict.new(full_path)
    end
    filename = File.basename(full_path)
    path = File.dirname(full_path)
    files_set = rev.files_at_path(path)
    rev.files.delete_at(rev.files.index(files_set[filename])) # delete file, but keep contents
    return rev
  end
  
  # Creates a deep copy of the provided revision, all files will have their changed property
  # set to false; does not create a deep copy the contents of files
  def copy_revision(original)
    # we only copy the RevisionFile/RevisionDirectory entries
    new_revision = MemoryRevision.new(original.revision_number)
    new_revision.user_id = original.user_id
    new_revision.comment = original.comment
    new_revision.files_content = {}
    # copy files objects
    original.files.each do |object|
      if object.instance_of?(RevisionFile)
        new_object = RevisionFile.new(object.from_revision, {
          :name => object.name,
          :path => object.path,
          :last_modified_revision => object.last_modified_revision,
          :changed => false, # for copies, set this to false
          :user_id => object.user_id
        })
        new_revision.files_content[new_object.to_s] = original.files_content[object.to_s]
      else
        new_object = RevisionDirectory.new(object.from_revision, {
          :name => object.name,
          :path => object.path,
          :last_modified_revision => object.last_modified_revision,
          :changed => false, # for copies, set this to false
          :user_id => object.user_id
        })
      end
      new_revision.files.push(new_object)
    end    
    return new_revision # return the copy
  end
  
  def file_exists?(rev, full_path)
    filename = File.basename(full_path)
    path = File.dirname(full_path)
    curr_files = rev.files_at_path(path)
    if !curr_files.nil?
      curr_files.each do |f, object|
        if f == filename
          return true
        end
      end
    end
    return false
  end
  
  # gets the "closest matching" revision from the revision-timestamp
  # mapping 
  def get_revision_number_by_timestamp(wanted_timestamp)
    if @timestamps_revisions.empty?
      raise "No revisions, so no timestamps."
    end
    
    timestamps_list = []
    @timestamps_revisions.keys().each do |time_dump|
      timestamps_list.push(Time._load(time_dump))
    end
    
    # find closest timestamp
    best_match = timestamps_list.shift()
    old_diff = wanted_timestamp - best_match
    mapping = {}
    mapping[old_diff.to_s] = best_match
    if !timestamps_list.empty?
      timestamps_list.each do |curr_timestamp|
        new_diff = wanted_timestamp - curr_timestamp
        mapping[new_diff.to_s] = curr_timestamp 
        if (old_diff <= 0 && new_diff <= 0) ||
           (old_diff <= 0 && new_diff > 0) ||
           (new_diff <= 0 && old_diff > 0)
          old_diff = [old_diff, new_diff].max
        else
          old_diff = [old_diff, new_diff].min
        end
      end
      wanted_timestamp = mapping[old_diff.to_s]
      return @timestamps_revisions[wanted_timestamp._dump]
    else
      return @current_revision
    end
  end

end # end class MemoryRepository

# Class responsible for storing files in and retrieving files 
# from memory
class MemoryRevision < Repository::AbstractRevision
   
  # getter/setters for instance variables
  attr_accessor :files, :changed_files, :files_content, :user_id, :comment
  
  # Constructor
  def initialize(revision_number)
    super(revision_number)
    @files = []           # files in this revision (<filename> <RevisionDirectory/RevisionFile>)
    @files_content = {}   # hash: keys => RevisionFile object, value => content
    @user_id = "dummy_user_id"     # user_id, who created this revision
    @comment = "commit_message" # commit-message for this revision
  end
  
  # Returns true if and only if path exists in files and path is a directory
  def path_exists?(path)
    if path == "/"
      return true # the root in a repository always exists
    end
    @files.each do |object|
      if object.instance_of?(RevisionDirectory)
        object_fqpn = object.path+object.name # fqpn is: fully qualified pathname :-)
        if object_fqpn.index("/") != 0
          object_fqpn = "/" + object_fqpn
        end        
        if object_fqpn == path
          return true
        end
      end
    end
    return false
  end
  
  # Return all of the files in this repository at the root directory
  def files_at_path(path="/")
    return nil if @files.empty?
    return files_at_path_helper(path)
  end
  
  def directories_at_path(path="/")
    return nil if @files.empty?
    return files_at_path_helper(path, false, RevisionDirectory)
  end
  
  def changed_files_at_path(path)
    return files_at_path_helper(path, true)
  end
  
  # Not (!) part of the AbstractRepository API:
  # A simple helper method to be used to add files to this
  # revision 
  def __add_file(file, content="")
    @files.push(file)
    if file.instance_of?(RevisionFile)
      @files_content[file.to_s] = content
    end
  end
  
  # Not (!) part of the AbstractRepository API:
  # A simple helper method to be used to add directories to this
  # revision
  def __add_directory(dir)
    __add_file(dir)
  end
  
  # Not (!) part of the AbstractRepository API:
  # A simple helper method to be used to increment the revision number
  def __increment_revision_number()
    @revision_number += 1
  end
  
  private
  
  def files_at_path_helper(path="/", only_changed=false, type=RevisionFile)
    result = Hash.new(nil)
    @files.each do |object|
      if object.instance_of?(type) && object.path == path
        if (!only_changed)
          object.from_revision = @revision_number # set revision number
          result[object.name] = object
        else
          if object.changed
            object.from_revision = @revision_number # reset revision number
            result[object.name] = object
          end
        end
      end
    end
    return result
  end
  
end # end class MemoryRevision

end # end Repository module
