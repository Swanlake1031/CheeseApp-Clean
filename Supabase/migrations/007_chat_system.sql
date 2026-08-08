-- ============================================
-- 007_chat_system.sql
-- 聊天系统数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建私信聊天相关的数据库表
-- 用于实现一对一的实时聊天功能
-- 
-- 🔧 设计思路：
-- 1. conversations 表存储会话（两个用户之间的聊天）
-- 2. messages 表存储具体的消息
-- 3. 使用 Supabase Realtime 实现实时推送
-- ============================================


-- ============================================
-- 会话表 (conversations)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 存储两个用户之间的会话信息
-- 每对用户只有一个会话，所有消息都在这个会话中

CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- ============================================
  -- 参与者
  -- ============================================
  
  -- user1_id 第一个用户
  -- 约定：user1_id 总是小于 user2_id（按 UUID 字符串比较）
  -- 这样可以确保同两个用户只有一个会话
  user1_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- user2_id 第二个用户
  user2_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- ============================================
  -- 关联帖子（可选）
  -- ============================================
  -- 如果是因为某个帖子开始的聊天，记录这个帖子
  -- 例如：用户咨询某个房源，就关联到那个租房帖子
  related_post_id UUID REFERENCES posts(id) ON DELETE SET NULL,
  
  -- ============================================
  -- 最后消息信息（冗余存储，提高列表查询性能）
  -- ============================================
  
  -- last_message_at 最后一条消息的时间
  -- 用于会话列表排序（最近的在前面）
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- last_message_preview 最后一条消息的预览
  -- 显示在会话列表中
  last_message_preview TEXT,
  
  -- ============================================
  -- 未读统计
  -- ============================================
  
  -- user1_unread_count 用户1 的未读消息数
  user1_unread_count INTEGER DEFAULT 0 CHECK (user1_unread_count >= 0),
  
  -- user2_unread_count 用户2 的未读消息数
  user2_unread_count INTEGER DEFAULT 0 CHECK (user2_unread_count >= 0),
  
  -- ============================================
  -- 时间戳
  -- ============================================
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- ============================================
  -- 约束
  -- ============================================
  
  -- 确保 user1_id 和 user2_id 不同
  CONSTRAINT different_users CHECK (user1_id != user2_id),
  
  -- 确保每对用户只有一个会话
  -- 因为我们约定 user1_id < user2_id，所以这个约束能保证唯一性
  UNIQUE(user1_id, user2_id)
);

-- 会话索引
CREATE INDEX conversations_user1_idx ON conversations (user1_id);
CREATE INDEX conversations_user2_idx ON conversations (user2_id);
CREATE INDEX conversations_last_message_idx ON conversations (last_message_at DESC);


-- ============================================
-- 消息表 (messages)
-- ============================================

CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 所属会话
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE NOT NULL,
  
  -- 发送者
  sender_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
  
  -- ============================================
  -- 消息内容
  -- ============================================
  
  -- content 文本内容
  content TEXT NOT NULL,
  
  -- message_type 消息类型
  -- text: 纯文本
  -- image: 图片
  -- post_share: 分享帖子
  message_type TEXT DEFAULT 'text' CHECK (message_type IN ('text', 'image', 'post_share')),
  
  -- metadata 额外数据（JSON 格式）
  -- 例如：图片 URL、分享的帖子信息等
  metadata JSONB DEFAULT '{}'::JSONB,
  
  -- ============================================
  -- 状态
  -- ============================================
  
  -- is_read 是否已读
  is_read BOOLEAN DEFAULT FALSE,
  
  -- read_at 阅读时间
  read_at TIMESTAMPTZ,
  
  -- is_deleted 是否删除（软删除）
  is_deleted BOOLEAN DEFAULT FALSE,
  
  -- ============================================
  -- 时间
  -- ============================================
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 消息索引
-- 按会话和时间查询消息
CREATE INDEX messages_conversation_idx ON messages (conversation_id, created_at DESC);
CREATE INDEX messages_sender_idx ON messages (sender_id);
CREATE INDEX messages_unread_idx ON messages (conversation_id, is_read) WHERE is_read = FALSE;


-- ============================================
-- 更新会话最后消息的触发器
-- ============================================
-- 
-- 🎯 作用：
-- 每次有新消息时，自动更新会话的：
-- 1. 最后消息时间
-- 2. 最后消息预览
-- 3. 接收方的未读计数

CREATE OR REPLACE FUNCTION update_conversation_last_message()
RETURNS TRIGGER AS $$
DECLARE
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  -- 获取会话的两个用户
  SELECT user1_id, user2_id INTO v_user1_id, v_user2_id
  FROM conversations WHERE id = NEW.conversation_id;
  
  -- 更新会话信息
  UPDATE conversations SET
    last_message_at = NEW.created_at,
    -- 截取消息预览（最多 50 个字符）
    last_message_preview = LEFT(NEW.content, 50),
    -- 更新未读计数：给对方加 1
    user1_unread_count = CASE 
      WHEN NEW.sender_id = v_user1_id THEN user1_unread_count  -- 发送者，不变
      ELSE user1_unread_count + 1  -- 接收者，加 1
    END,
    user2_unread_count = CASE 
      WHEN NEW.sender_id = v_user2_id THEN user2_unread_count
      ELSE user2_unread_count + 1
    END,
    updated_at = NOW()
  WHERE id = NEW.conversation_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER messages_update_conversation_trigger
  AFTER INSERT ON messages
  FOR EACH ROW
  EXECUTE FUNCTION update_conversation_last_message();


-- ============================================
-- 创建或获取会话的函数
-- ============================================
-- 
-- 🎯 作用：
-- 如果两个用户之间已有会话，返回现有的
-- 如果没有，创建一个新的
-- 这样可以避免创建重复的会话

CREATE OR REPLACE FUNCTION get_or_create_conversation(
  p_user_id UUID,         -- 当前用户
  p_other_user_id UUID,   -- 对方用户
  p_related_post_id UUID DEFAULT NULL  -- 关联帖子（可选）
)
RETURNS UUID AS $$
DECLARE
  v_conversation_id UUID;
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  -- 确定 user1 和 user2 的顺序
  -- 总是让较小的 UUID 作为 user1
  IF p_user_id < p_other_user_id THEN
    v_user1_id := p_user_id;
    v_user2_id := p_other_user_id;
  ELSE
    v_user1_id := p_other_user_id;
    v_user2_id := p_user_id;
  END IF;
  
  -- 尝试获取现有会话
  SELECT id INTO v_conversation_id
  FROM conversations
  WHERE user1_id = v_user1_id AND user2_id = v_user2_id;
  
  -- 如果不存在，创建新会话
  IF v_conversation_id IS NULL THEN
    INSERT INTO conversations (user1_id, user2_id, related_post_id)
    VALUES (v_user1_id, v_user2_id, p_related_post_id)
    RETURNING id INTO v_conversation_id;
  END IF;
  
  RETURN v_conversation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 标记消息已读的函数
-- ============================================

CREATE OR REPLACE FUNCTION mark_messages_as_read(
  p_conversation_id UUID,
  p_user_id UUID
)
RETURNS VOID AS $$
DECLARE
  v_user1_id UUID;
BEGIN
  -- 获取 user1_id 来判断当前用户是哪一方
  SELECT user1_id INTO v_user1_id
  FROM conversations WHERE id = p_conversation_id;
  
  -- 标记消息已读
  UPDATE messages
  SET is_read = TRUE, read_at = NOW()
  WHERE conversation_id = p_conversation_id
    AND sender_id != p_user_id
    AND is_read = FALSE;
  
  -- 重置未读计数
  IF p_user_id = v_user1_id THEN
    UPDATE conversations SET user1_unread_count = 0 WHERE id = p_conversation_id;
  ELSE
    UPDATE conversations SET user2_unread_count = 0 WHERE id = p_conversation_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建会话列表视图
-- ============================================
-- 
-- 🎯 这个视图需要根据当前用户动态查询
-- 所以用函数来实现

CREATE OR REPLACE FUNCTION get_user_conversations(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  related_post_id UUID,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  unread_count INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    -- 对方用户 ID
    CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END,
    -- 对方用户名
    CASE WHEN c.user1_id = p_user_id THEN p2.full_name ELSE p1.full_name END,
    -- 对方头像
    CASE WHEN c.user1_id = p_user_id THEN p2.avatar_url ELSE p1.avatar_url END,
    c.related_post_id,
    c.last_message_at,
    c.last_message_preview,
    -- 当前用户的未读数
    CASE WHEN c.user1_id = p_user_id THEN c.user1_unread_count ELSE c.user2_unread_count END
  FROM conversations c
  JOIN profiles p1 ON c.user1_id = p1.id
  JOIN profiles p2 ON c.user2_id = p2.id
  WHERE c.user1_id = p_user_id OR c.user2_id = p_user_id
  ORDER BY c.last_message_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 🎉 完成！
-- ============================================
